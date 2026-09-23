#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GitHub 虚拟机管理工作台 —— 离线自测（零依赖）。

不联网、不碰真机：把 server.py 以 offline 模式在随机端口跑起来，
逐个打 API，校验状态码与关键字段；再单测几个纯函数。

    python workbench/selftest.py
"""
from __future__ import annotations

import base64
import json
import os
import re
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402

PASS = 0
FAIL = 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  PASS  %s" % name)
    else:
        FAIL += 1
        FAILURES.append(name)
        print("  FAIL  %s  %s" % (name, detail))


def req(base, path, method="GET", body=None):
    url = base + path
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method,
                               headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            return resp.status, resp.read().decode("utf-8", "replace"), resp.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), e.headers.get("Content-Type", "")


def main():
    server.OFFLINE = True
    server.QUIET = True
    tmpdir = tempfile.mkdtemp(prefix="wb-test-")
    server.CONFIG["rdp_dir"] = tmpdir
    server.CONFIG["rdp_launch"] = False
    server.CONFIG["rdp_store_cred"] = False

    httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    base = "http://127.0.0.1:%d" % port
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    print("离线服务已起：%s\n" % base)

    # ---------------- 静态资源 ----------------
    print("[静态]")
    code, body, ctype = req(base, "/")
    check("T01 GET / → 200 html", code == 200 and "text/html" in ctype, "code=%s ctype=%s" % (code, ctype))
    check("T02 index 含标题", "GitHub虚拟机管理工作台" in body)
    code, body, ctype = req(base, "/app.js")
    check("T03 GET /app.js → 200 js", code == 200 and "javascript" in ctype, "code=%s" % code)
    code, body, ctype = req(base, "/styles.css")
    check("T04 GET /styles.css → 200 css", code == 200 and "text/css" in ctype, "code=%s" % code)
    code, _, _ = req(base, "/nope.txt")
    check("T05 未知静态 → 404", code == 404, "code=%s" % code)

    # ---------------- /api/health ----------------
    print("[API health]")
    code, body, _ = req(base, "/api/health")
    d = json.loads(body)
    check("T06 health 200/ok", code == 200 and d.get("ok") is True)
    check("T07 health 有 version/repo/started_at",
          bool(d.get("version")) and bool(d.get("repo")) and bool(d.get("started_at")))
    check("T08 health 标记 offline", d.get("offline") is True)

    # ---------------- /api/overview ----------------
    print("[API overview]")
    code, body, _ = req(base, "/api/overview")
    d = json.loads(body)
    check("T09 overview 200/ok", code == 200 and d.get("ok") is True, "code=%s" % code)
    for key in ("config", "stats", "accounts", "machines", "pool_state", "runs", "errors"):
        check("T10 overview 含 %s" % key, key in d)
    check("T11 stats 有 machines_online", "machines_online" in (d.get("stats") or {}))
    check("T12 machines 是 list", isinstance(d.get("machines"), list))
    check("T13 runs 是 dict", isinstance(d.get("runs"), dict))
    check("T14 errors 是 list", isinstance(d.get("errors"), list))
    check("T15 config.token_present 是 bool", isinstance((d.get("config") or {}).get("token_present"), bool))

    # ---------------- /api/accounts ----------------
    print("[API accounts]")
    code, body, _ = req(base, "/api/accounts")
    d = json.loads(body)
    check("T16 accounts 200", code == 200)
    check("T17 accounts.ok 是 bool", isinstance(d.get("ok"), bool))
    if d.get("ok"):
        accs = d.get("accounts") or []
        check("T18 accounts 列表字段完整",
              all(all(k in a for k in ("id", "owner", "enabled", "token_secret", "alive", "role",
                                       "token_state", "alive_count", "last_run", "source",
                                       "provisioning"))
                  for a in accs))
        check("T18b accounts 带监测元信息",
              all(k in d for k in ("monitor_available", "state_updated", "state_age_human", "state_via")))
        check("T19 accounts 至少 1 个（真实 pool-config）", len(accs) >= 1, "n=%d" % len(accs))
    else:
        check("T18 accounts 降级有 error", bool(d.get("error")))
        check("T19 accounts 降级返回空列表", d.get("accounts") == [])

    # ---------------- /api/machines ----------------
    print("[API machines]")
    code, body, _ = req(base, "/api/machines")
    d = json.loads(body)
    check("T20 machines 200", code == 200)
    check("T21 machines 有 machines 列表", isinstance(d.get("machines"), list))
    check("T22 machines.ok 是 bool", isinstance(d.get("ok"), bool))

    # ---------------- /api/runs ----------------
    print("[API runs]")
    code, body, _ = req(base, "/api/runs")
    d = json.loads(body)
    check("T23 runs 200", code == 200)
    check("T24 runs 含 keepalive/coordinator", "keepalive" in d and "coordinator" in d)
    code, body, _ = req(base, "/api/runs?workflow=keepalive")
    check("T25 runs?workflow=keepalive 200", code == 200)

    # ---------------- /api/pool-state ----------------
    print("[API pool-state]")
    code, body, _ = req(base, "/api/pool-state")
    d = json.loads(body)
    check("T26 pool-state 200", code == 200)
    check("T27 pool-state.ok 是 bool", isinstance(d.get("ok"), bool))

    # ---------------- 派发（离线无 token → 优雅失败） ----------------
    print("[API dispatch]")
    code, body, _ = req(base, "/api/dispatch", "POST", {"target": "coordinator"})
    d = json.loads(body)
    check("T28 dispatch 返回 JSON 且带 ok", "ok" in d, body[:200])
    check("T29 dispatch 非法 target → 400",
          req(base, "/api/dispatch", "POST", {"target": "bogus"})[0] == 400)

    # ---------------- 一键登录 ----------------
    print("[API rdp]")
    code, body, ctype = req(base, "/api/rdp/preview?ip=100.1.2.3")
    check("T30 rdp preview 200 文本", code == 200 and "full address:s:100.1.2.3" in body)
    check("T31 rdp preview 含 username", "username:s:" in body)

    code, body, _ = req(base, "/api/rdp", "POST", {"ip": "100.9.9.9", "hostname": "github-rdp-server-99"})
    d = json.loads(body)
    check("T32 rdp 生成 200/ok", code == 200 and d.get("ok") is True, body[:200])
    if d.get("ok"):
        check("T33 .rdp 文件已落盘", os.path.isfile(d["path"]), d.get("path"))
        content = open(d["path"], "r", encoding="utf-8").read()
        check("T34 .rdp 含目标 IP", "full address:s:100.9.9.9" in content)
        check("T35 .rdp 关闭凭据提示", "prompt for credentials:i:0" in content)
        check("T36 未唤起（测试模式）", d.get("launched") is False)
    check("T37 非法 IP → 400", req(base, "/api/rdp", "POST", {"ip": "a b;rm"})[0] == 400)

    # ---------------- 连接信息（「查看信息」按钮） ----------------
    print("[API conn-info]")
    code, body, ctype = req(base, "/api/conn-info?ip=100.1.2.3")
    d = json.loads(body)
    check("T79 conn-info 200/ok", code == 200 and d.get("ok") is True, body[:200])
    check("T80 conn-info 回显 IP", d.get("ip") == "100.1.2.3", str(d.get("ip")))
    check("T81 conn-info 含用户名/密码", d.get("username") == "a" and d.get("password") == "a", body[:200])
    check("T82 conn-info 缺 ip 不炸", req(base, "/api/conn-info")[0] == 200)
    check("T83 machine_detail 含运行时长字段",
          all(k in server.machine_detail("100.1.2.3", False)
              for k in ("uptime_seconds", "uptime_human", "started_utc")))

    # ---------------- 机器归属账号 + 日志缩略 ----------------
    print("[机器归属 / 日志缩略]")
    check("T84 index 日志缩略按钮带 data-limit=5",
          'data-collapse="runs" data-limit="5"' in req(base, "/")[1])
    check("T85 machine_detail 含归属账号字段",
          all(k in server.machine_detail("100.1.2.3", False)
              for k in ("pool_owner", "pool_id", "assigned_role", "owner_source")))
    pi = server.parse_pool_info("pool_id=p1\npool_owner=alice\nassigned_role=primary\n")
    check("T86 parse_pool_info 解析 key=value",
          pi.get("pool_owner") == "alice" and pi.get("assigned_role") == "primary", str(pi))
    check("T87 parse_pool_info 空文本/无等号行不炸",
          server.parse_pool_info("") == {} and server.parse_pool_info("noeq\n\n  \n") == {})
    ms = server.map_machine_accounts([{"pool_owner": "alice"}, {"pool_owner": "bob"}, {}],
                                     [{"id": "acc-1", "owner": "alice"}])
    check("T88 map_machine_accounts 映射 owner→id",
          ms[0].get("account_id") == "acc-1", str(ms))
    check("T89 未登记 owner / 无 owner → account_id 为空",
          ms[1].get("account_id") == "" and ms[2].get("account_id") == "", str(ms))
    check("T90 _unc_abs 按盘符拼共享名",
          server._unc_abs("1.2.3.4", r"D:\a\cloud-rdp\cloud-rdp\.git\config")
          == "\\\\1.2.3.4\\D$\\a\\cloud-rdp\\cloud-rdp\\.git\\config",
          server._unc_abs("1.2.3.4", r"D:\a\x\.git\config"))
    check("T91 parse_git_origin_owner 解析普通 URL",
          server.parse_git_origin_owner('[remote "origin"]\n\turl = https://github.com/acct9/cloud-rdp\n')
          == "acct9")
    gc = server.parse_git_origin_owner('[remote "origin"]\n\turl = https://x-access-token:SECRET123@github.com/acct9/cloud-rdp.git\n')
    check("T92 带 token 的 URL 只取 owner（不外泄 token）",
          gc == "acct9" and "SECRET123" not in gc, repr(gc))
    check("T93 非 GitHub / 空文本 → 空",
          server.parse_git_origin_owner("") == ""
          and server.parse_git_origin_owner('[remote "origin"]\n\turl = https://gitlab.com/a/b\n') == "")

    # ---------------- 一键登录：mstsc /v: 零弹窗（KB5083769 后） ----------------
    print("[一键登录 / Default.rdp]")
    check("T94 default_rdp_path 指向 Documents\\Default.rdp",
          os.path.basename(server.default_rdp_path()) == "Default.rdp"
          and "Documents" in server.default_rdp_path(), server.default_rdp_path())
    st = server.default_rdp_status()
    check("T95 default_rdp_status 字段齐全",
          all(k in st for k in ("path", "exists", "auth_level", "auth_zero", "backup")), str(st))
    check("T96 默认唤起方式 = mstsc（命令行，不受 .rdp 安全警告影响）",
          server.DEFAULT_CONFIG.get("rdp_launch_mode") == "mstsc")
    ci = json.loads(req(base, "/api/conn-info?ip=1.2.3.4")[1])
    check("T97 /api/conn-info 带 launch_mode + default_rdp",
          ci.get("launch_mode") == "mstsc" and isinstance(ci.get("default_rdp"), dict), str(ci))
    dd = req(base, "/api/rdp/default")
    dj = json.loads(dd[1])
    check("T98 GET /api/rdp/default → 200 且含 auth_zero",
          dd[0] == 200 and dj.get("ok") is True and "auth_zero" in dj, str(dj))
    if server.IS_WINDOWS:
        _popen, _ensure = server.subprocess.Popen, server.ensure_default_rdp_auth_level
        calls = {}

        class _FakePopen(object):
            def __init__(self, args, *a, **k):
                calls["args"] = args

        server.subprocess.Popen = _FakePopen
        server.ensure_default_rdp_auth_level = lambda: (True, "stub")
        try:
            lr = server.launch_rdp("1.2.3.4", "x.rdp")
        finally:
            server.subprocess.Popen = _popen
            server.ensure_default_rdp_auth_level = _ensure
        check("T99 launch_rdp 走 mstsc /v:IP 且返回四元组",
              lr[0] is True and lr[2] == "mstsc"
              and calls.get("args", [None, ""])[:2] == ["mstsc", "/v:1.2.3.4"],
              "%s / %s" % (lr, calls))
    else:
        check("T99 非 Windows：launch_rdp 不唤起",
              server.launch_rdp("1.2.3.4", "x.rdp")[0] is False)

    # ---------------- 路由健壮性 ----------------
    print("[路由]")
    check("T38 未知 API → 404", req(base, "/api/nope")[0] == 404)
    check("T39 静态路径 POST → 405", req(base, "/", "POST", {})[0] == 405)
    # 回归：预览面板/浏览器探活会先发 HEAD，曾经返回 501 被误判成「服务不可用」
    check("T39a HEAD / → 200（探活）", req(base, "/", "HEAD")[0] == 200)
    check("T39b HEAD /api/health → 200（探活）", req(base, "/api/health", "HEAD")[0] == 200)
    check("T39c HEAD /styles.css → 200（探活）", req(base, "/styles.css", "HEAD")[0] == 200)

    # ---------------- 纯函数 ----------------
    print("[纯函数]")
    check("T40 _unc 拼接正确",
          server._unc("1.2.3.4", "_state/pool-role.txt") == "\\\\1.2.3.4\\D$\\cloudrdp-sys\\_state\\pool-role.txt",
          server._unc("1.2.3.4", "_state/pool-role.txt"))
    check("T41 human_age 空值不炸", server.human_age("") == "")
    check("T42 human_duration", server.human_duration(3725) == "1h02m", server.human_duration(3725))
    check("T43 parse_iso 往返", server.parse_iso("2026-09-22T01:00:00Z") is not None)
    check("T44 _shape_run 关键字段",
          all(k in server._shape_run({}) for k in ("id", "state", "in_progress", "url")))
    check("T105 beijing_time UTC→北京时间（UTC+8，格式 2026/9/22-20:16）",
          server.beijing_time("2026-09-22T03:31:03Z") == "2026/9/22-11:31",
          server.beijing_time("2026-09-22T03:31:03Z"))
    check("T106 beijing_time 容忍 7 位小数秒",
          server.beijing_time("2026-09-22T03:31:03.7302008Z") == "2026/9/22-11:31",
          server.beijing_time("2026-09-22T03:31:03.7302008Z"))
    check("T107 beijing_time 已是 +08:00 不再偏移",
          server.beijing_time("2026-09-22T11:31:03+08:00") == "2026/9/22-11:31",
          server.beijing_time("2026-09-22T11:31:03+08:00"))
    check("T108 beijing_time 月/日不补零、时:分补零",
          server.beijing_time("2026-01-05T16:00:00Z") == "2026/1/6-00:00",
          server.beijing_time("2026-01-05T16:00:00Z"))
    check("T109 beijing_time 空值不炸", server.beijing_time("") == "")
    check("T110 _shape_run 带 created_beijing",
          "created_beijing" in server._shape_run({"created_at": "2026-09-22T03:31:03Z"}))
    check("T111 shape_last_run 带 created_beijing",
          "created_beijing" in server.shape_last_run({"created_at": "2026-09-22T03:31:03Z"}))

    # ---------------- 回归：get_runs 真实代码路径（离线分支会提前 return，覆盖不到） ----------------
    print("[回归 get_runs]")
    real_offline = server.OFFLINE
    real_gh = server.gh_api
    try:
        server.OFFLINE = False
        server.clear_cache()
        server.gh_api = lambda *a, **k: {"workflow_runs": [{
            "id": 1, "run_number": 7, "display_title": "t", "name": "Windows Cloud RDP",
            "path": ".github/workflows/windows-rdp.yml", "event": "schedule",
            "status": "completed", "conclusion": "success",
            "created_at": "2026-09-22T01:00:00Z", "updated_at": "2026-09-22T01:30:00Z",
            "run_started_at": "2026-09-22T01:00:00Z", "head_sha": "abcdef1234567890",
            "html_url": "https://example.invalid/1"}]}
        runs = server.get_runs(limit=3)
        check("T45 get_runs 不再抛 UnboundLocalError", runs.get("ok") is True, str(runs)[:200])
        check("T46 get_runs 解析出 run", len(runs.get("keepalive") or []) == 1)
        check("T47 get_runs 用时格式化为 30m00s",
              (runs.get("keepalive") or [{}])[0].get("duration") == "30m00s",
              str((runs.get("keepalive") or [{}])[0].get("duration")))
    finally:
        server.OFFLINE = real_offline
        server.gh_api = real_gh
        server.clear_cache()

    # ---------------- 回归：pool_state raw 失败 → 回退 GitHub API ----------------
    print("[回归 get_pool_state]")
    real_offline = server.OFFLINE
    real_http = server.http_json
    real_gh = server.gh_api

    def boom(*a, **k):
        raise RuntimeError("raw 挂了")

    try:
        server.OFFLINE = False
        server.clear_cache()
        server.http_json = boom
        payload = json.dumps({"version": 1, "primary": {"owner": "o1"}}).encode("utf-8")
        server.gh_api = lambda *a, **k: {"content": base64.b64encode(payload).decode()}
        ps = server.get_pool_state()
        check("T48 raw 失败 → 回退 API 成功", ps.get("ok") is True and ps.get("via") == "api",
              str(ps)[:200])
        check("T49 回退后解出 primary",
              ((ps.get("state") or {}).get("primary") or {}).get("owner") == "o1")
    finally:
        server.OFFLINE = real_offline
        server.http_json = real_http
        server.gh_api = real_gh
        server.clear_cache()

    # ---------------- 纯函数：时间解析 / 监测数据整形 ----------------
    print("[监测数据整形]")
    dt = server.parse_iso("2026-09-22T03:31:03.7302008Z")   # PowerShell ToString('o') 的 7 位小数
    check("T50 parse_iso 认 7 位小数（PS 'o' 格式）",
          dt is not None and dt.hour == 3 and dt.minute == 31 and dt.second == 3, str(dt))
    check("T51 human_age 能算 7 位小数时间", server.human_age("2026-09-22T03:31:03.7302008Z") != "")

    reps = server.pool_account_reports({"accounts": [{"owner": "o1", "token_state": "ok"}]})
    check("T52 pool_account_reports 解析 list", reps.get("o1", {}).get("token_state") == "ok")
    check("T53 pool_account_reports 容错单条 dict",
          "o2" in server.pool_account_reports({"accounts": {"owner": "o2"}}))
    check("T54 pool_account_reports 缺字段不炸", server.pool_account_reports({}) == {})

    lr = server.shape_last_run({"run_id": 9, "status": "completed", "conclusion": "success",
                                "created_at": "2026-09-22T01:00:00Z", "event": "schedule", "url": "u"})
    check("T55 shape_last_run 统一 pool-state 形态",
          lr["id"] == 9 and lr["state"] == "success" and lr["url"] == "u")
    lr2 = server.shape_last_run({"id": 7, "state": "in_progress", "conclusion": "", "created_at": "x"})
    check("T56 shape_last_run 统一 runs 形态", lr2["id"] == 7 and lr2["state"] == "in_progress")
    check("T57 shape_last_run 空值返回 None", server.shape_last_run(None) is None)

    # ---------------- get_accounts 合并 pool-state 监测明细 ----------------
    print("[get_accounts 合并监测]")
    real_pc = server.CONFIG.get("pool_config")
    real_pool = server.get_pool_state
    real_secrets = server.get_secret_names
    tmpcfg = os.path.join(tmpdir, "pool-config.json")
    with open(tmpcfg, "w", encoding="utf-8") as f:
        json.dump({"pool_id": "t", "target_machines": 1, "hub": {"owner": "hubby"},
                   "accounts": [
                       {"id": "acc-1", "owner": "acct1", "repo": "cloud-rdp",
                        "token_secret": "POOL_TOKEN_1", "enabled": True},
                       {"id": "acc-2", "owner": "acct2", "repo": "cloud-rdp",
                        "token_secret": "POOL_TOKEN_2", "enabled": True}]}, f)
    try:
        server.CONFIG["pool_config"] = tmpcfg
        server.clear_cache()
        server.get_pool_state = lambda: {"ok": True, "via": "raw", "state": {
            "version": 1, "updated_utc": "2026-09-22T03:31:03.7302008Z", "target_machines": 1,
            "primary": {"owner": "acct1", "run_id": 11, "since": "2026-09-22T01:00:00Z"},
            "standby": [],
            "accounts": [
                {"id": "acc-1", "owner": "acct1", "repo": "cloud-rdp", "enabled": True,
                 "secret_name": "POOL_TOKEN_1", "token_state": "ok", "alive_count": 1, "total": 5,
                 "last_run": {"run_id": 11, "status": "in_progress", "conclusion": "",
                              "created_at": "2026-09-22T01:00:00Z",
                              "event": "workflow_dispatch", "url": "u1"},
                 "note": "", "role": "primary"},
                {"id": "acc-2", "owner": "acct2", "repo": "cloud-rdp", "enabled": True,
                 "secret_name": "POOL_TOKEN_2", "token_state": "missing", "alive_count": 0,
                 "total": 0, "last_run": None, "note": "Secret POOL_TOKEN_2 未配置", "role": ""}]}}
        server.get_secret_names = lambda: {"POOL_TOKEN_1"}
        acc = server.get_accounts()
        check("T58 get_accounts ok", acc.get("ok") is True)
        check("T59 监测数据可用标记", acc.get("monitor_available") is True)
        check("T60 池状态更新时间解析出来", acc.get("state_age_human") != "", str(acc.get("state_updated")))
        a1 = (acc.get("accounts") or [{}])[0]
        check("T61 acc-1 token_state 透传", a1.get("token_state") == "ok")
        check("T62 acc-1 alive_count 透传", a1.get("alive_count") == 1)
        check("T63 acc-1 role 取自明细", a1.get("role") == "primary")
        check("T64 acc-1 last_run 整形", (a1.get("last_run") or {}).get("id") == 11)
        check("T65 acc-1 secret_present 由 Secret 名推断", a1.get("secret_present") is True)
        a2 = (acc.get("accounts") or [{}, {}])[1]
        check("T66 acc-2 token_state = missing", a2.get("token_state") == "missing")
        check("T67 acc-2 提示语透传", "未配置" in (a2.get("report_note") or ""))
        check("T68 acc-2 secret_present False", a2.get("secret_present") is False)

        # ---- POOL_TOKENS（JSON 通道）：值不可读 → 不得误报「缺失」 ----
        server.clear_cache()
        server.get_secret_names = lambda: {"POOL_TOKENS"}
        accp = server.get_accounts()
        p1 = (accp.get("accounts") or [{}])[0]
        p2 = (accp.get("accounts") or [{}, {}])[1]
        check("T77 token_state=ok → 已配置（JSON 通道）",
              p1.get("secret_present") is True and p1.get("secret_via") == "pool_tokens")
        check("T78 JSON 通道未确认 → 存疑而非缺失",
              p2.get("secret_present") is None and p2.get("secret_via") == "pool_tokens")

        # ---------------- 新增账号 API ----------------
        print("[API accounts/add]")
        code, body, _ = req(base, "/api/accounts/add", "POST",
                            {"owner": "acct3", "repo": "cloud-rdp", "token_secret": "POOL_TOKEN_3",
                             "pat": "ghp_dummy", "auto_deploy": False})
        d = json.loads(body)
        check("T69 add 200/ok", code == 200 and d.get("ok") is True, body[:200])
        check("T70 add 自动生成 id", (d.get("id") or "").startswith("acc-"), str(d.get("id")))
        with open(tmpcfg, encoding="utf-8") as f:
            saved = json.load(f)
        check("T71 已写回配置文件", any(a.get("owner") == "acct3" for a in saved.get("accounts") or []))
        check("T72 add 返回 Secret 提示", "POOL_TOKENS" in (d.get("hint") or ""))

        # 新规则：必填只有 PAT；Secret 名可留空 → 自动分配 POOL_TOKEN_N
        code, body, _ = req(base, "/api/accounts/add", "POST",
                            {"owner": "acct4", "repo": "cloud-rdp", "pat": "ghp_dummy",
                             "auto_deploy": False})
        d4 = json.loads(body)
        check("T72a 不填 Secret 名也能加（200/ok）", code == 200 and d4.get("ok") is True, body[:200])
        check("T72b Secret 名自动分配 POOL_TOKEN_4（跳过已占用的 1/2/3）",
              d4.get("token_secret") == "POOL_TOKEN_4" and d4.get("secret_auto") is True,
              str(d4.get("token_secret")))
        with open(tmpcfg, encoding="utf-8") as f:
            saved4 = json.load(f)
        check("T72c 自动分配的 Secret 名已写回配置",
              any(a.get("owner") == "acct4" and a.get("token_secret") == "POOL_TOKEN_4"
                  for a in saved4.get("accounts") or []))
        code, body, _ = req(base, "/api/accounts/add", "POST",
                            {"owner": "acct5", "repo": "cloud-rdp"})
        check("T72d 不填 PAT → 400（PAT 必填）", code == 400, "code=%s" % code)

        code, _, _ = req(base, "/api/accounts/add", "POST",
                         {"owner": "acct3", "repo": "cloud-rdp", "token_secret": "X",
                          "pat": "ghp_dummy"})
        check("T73 重复 owner → 409", code == 409, "code=%s" % code)
        code, _, _ = req(base, "/api/accounts/add", "POST",
                         {"owner": "", "repo": "r", "token_secret": "S", "pat": "ghp_dummy"})
        check("T74 空 owner → 400", code == 400, "code=%s" % code)
        code, _, _ = req(base, "/api/accounts/add", "POST",
                         {"owner": "acct9", "repo": "r", "token_secret": "1bad", "pat": "ghp_dummy"})
        check("T75 非法 Secret 名 → 400", code == 400, "code=%s" % code)
        code, _, _ = req(base, "/api/accounts/add", "POST",
                         {"owner": "acct9", "repo": "r", "token_secret": "OK_NAME", "id": "acc-1",
                          "pat": "ghp_dummy"})
        check("T76 重复 id → 409", code == 409, "code=%s" % code)
        code, _, _ = req(base, "/api/accounts/add", "POST",
                         {"owner": "acct9", "repo": "r", "token_secret": "POOL_TOKEN_1",
                          "pat": "ghp_dummy"})
        check("T78 重复 Secret 名 → 409", code == 409, "code=%s" % code)
    finally:
        server.get_pool_state = real_pool
        server.get_secret_names = real_secrets
        if real_pc is None:
            server.CONFIG.pop("pool_config", None)
        else:
            server.CONFIG["pool_config"] = real_pc
        server.clear_cache()

    # ---------------- 快照 manifest 解析（新/旧字段兼容 + 快照时间） ----------------
    print("[快照 manifest 解析]")
    newman = {
        "createdUtc": "2026-09-20T01:23:45.7302008Z",
        "createdLocal": "2026-09-20T09:23:45.7302008+08:00",
        "files": {"totalFiles": 1234, "totalBytes": 5678, "entries": 1, "skipped": 0},
        "mode": "quick", "status": "OK",
    }
    sn = server.parse_snapshot_manifest(newman)
    check("T80 新格式 files.totalFiles 解析", sn.get("files") == 1234, str(sn.get("files")))
    check("T81 新格式 files.totalBytes 解析", sn.get("bytes") == 5678, str(sn.get("bytes")))
    check("T82 生成 created_local（本机时区）", bool(sn.get("created_local")), repr(sn.get("created_local")))
    check("T83 保留 mode/status", sn.get("mode") == "quick" and sn.get("status") == "OK", str(sn))
    check("T84 age_human 非空", bool(sn.get("age_human")))
    so = server.parse_snapshot_manifest({"file_count": 9, "created_utc": "2026-09-20T01:00:00Z"})
    check("T85 老格式 file_count 兼容", so.get("files") == 9, str(so.get("files")))
    check("T86 老格式 created_utc → created_local", bool(so.get("created_local")), repr(so.get("created_local")))
    check("T87 非 dict 返回 None", server.parse_snapshot_manifest("x") is None)
    st = server.parse_snapshot_manifest({"createdUtc": "2000-01-01T00:00:00Z", "files": {"totalFiles": 1}})
    check("T88 超期快照 stale=True", st.get("stale") is True, str(st))

    # ---------------- 一键备份（请求文件下发 / 读取） ----------------
    print("[一键备份]")
    real_write = server.write_remote_text
    real_read = server.read_remote_text
    store = {}

    def fake_write(ip, rel, text):
        store[(ip, rel)] = text

    def fake_read(ip, rel):
        return store.get((ip, rel), "")

    server.write_remote_text = fake_write
    server.read_remote_text = fake_read
    try:
        rb = server.request_backup("100.64.0.9", requested_by="tester")
        check("T89 request_backup ok", rb.get("ok") is True, str(rb))
        check("T90 请求文件路径正确", rb.get("file") == "_state/backup-request.txt", str(rb.get("file")))
        body = store.get(("100.64.0.9", "_state/backup-request.txt"), "")
        check("T91 请求体含 requested_at/by", "requested_at=" in body and "requested_by=tester" in body, body)
        rq = server.read_backup_request("100.64.0.9")
        check("T92 read_backup_request pending=True", rq.get("pending") is True, str(rq))
        check("T93 requested_by 解析", rq.get("requested_by") == "tester", str(rq))
        check("T94 无请求 pending=False", server.read_backup_request("100.64.0.8").get("pending") is False)
        check("T95 非法 ip → ok=False", server.request_backup("bad ip!").get("ok") is False)
        check("T96 缺 ip → ok=False", server.request_backup("").get("ok") is False)
    finally:
        server.write_remote_text = real_write
        server.read_remote_text = real_read

    # ---------------- SMB 后端选择（Windows UNC / Linux smbclient） ----------------
    print("[SMB 后端]")
    real_mode = server.CONFIG.get("smb_mode")
    real_win = server.IS_WINDOWS
    try:
        server.CONFIG["smb_mode"] = "smbclient"
        check("T101 smb_mode=smbclient → smbclient", server.smb_backend() == "smbclient", server.smb_backend())
        server.CONFIG["smb_mode"] = "unc"
        check("T102 smb_mode=unc → unc", server.smb_backend() == "unc", server.smb_backend())
        server.CONFIG["smb_mode"] = "auto"
        server.IS_WINDOWS = True
        check("T103 auto + Windows → unc", server.smb_backend() == "unc", server.smb_backend())
        server.IS_WINDOWS = False
        check("T104 auto + Linux → smbclient", server.smb_backend() == "smbclient", server.smb_backend())
    finally:
        server.IS_WINDOWS = real_win
        if real_mode is None:
            server.CONFIG.pop("smb_mode", None)
        else:
            server.CONFIG["smb_mode"] = real_mode

    # ---------------- 访问令牌（access_token 保护） ----------------
    print("[访问令牌]")
    server.CONFIG["access_token"] = "s3cr3t"
    try:
        code, _, _ = req(base, "/api/health")
        check("T97 无 token → 401", code == 401, "code=%s" % code)
        code, body, _ = req(base, "/api/health?token=s3cr3t")
        check("T98 正确 token → 200", code == 200 and json.loads(body).get("ok") is True, "code=%s" % code)
        code, _, _ = req(base, "/api/health?token=wrong")
        check("T99 错误 token → 401", code == 401, "code=%s" % code)
        code, _, _ = req(base, "/")
        check("T100 无 token 访问首页 → 401", code == 401, "code=%s" % code)
    finally:
        server.CONFIG["access_token"] = ""

    # ---------------- 回归：Windows 启动脚本必须纯 ASCII ----------------
    # 事故：open-workbench.vbs 曾是「UTF-8 无 BOM」，WSH 按 ANSI/GBK 解码，
    # 多字节序列吞掉一个引号 → 编译器报「语句未结束」(0x800A0401)。cmd/ps1 同理。
    print("[启动脚本编码]")
    wb_dir = os.path.dirname(os.path.abspath(__file__))
    for fn in ("open-workbench.vbs", "serve.cmd", "start.cmd"):
        fp = os.path.join(wb_dir, fn)
        if not os.path.exists(fp):
            check("T112 %s 存在" % fn, False, fp)
            continue
        blob = open(fp, "rb").read()
        has_bom = blob[:3] == b"\xef\xbb\xbf" or blob[:2] in (b"\xff\xfe", b"\xfe\xff")
        check("T112 %s 无 BOM" % fn, not has_bom, "有 BOM：WSH/cmd 会报无效字符")
        try:
            blob.decode("ascii")
            ok, why = True, ""
        except UnicodeDecodeError as e:
            ok = False
            why = "含非 ASCII 字节@%d：Windows 按 ANSI/GBK 解码会吞引号/括号 → 0x800A0401" % e.start
        check("T113 %s 纯 ASCII" % fn, ok, why)

    # 端口一致性：.vbs 写死的 PORT/URL 必须与后端默认端口一致（防止两边漂移）
    vbs_txt = open(os.path.join(wb_dir, "open-workbench.vbs"), encoding="ascii").read()
    m = re.search(r"Const PORT\s*=\s*(\d+)", vbs_txt)
    vbs_port = int(m.group(1)) if m else -1
    srv_port = int(server.CONFIG.get("port", -1))
    check("T114 open-workbench.vbs 端口与后端默认一致(%d)" % srv_port, vbs_port == srv_port,
          "vbs=%s server=%s" % (vbs_port, srv_port))
    check("T114b open-workbench.vbs URL 含 127.0.0.1:%d" % srv_port,
          ("127.0.0.1:%d" % srv_port) in vbs_txt, "URL 里没有该端口")

    # ---------------- 新增账号：自动部署仓库 + 接入账号池（provision） ----------------
    print("[自动部署 provision]")
    html = open(os.path.join(wb_dir, "static", "index.html"), encoding="utf-8").read()
    appjs = open(os.path.join(wb_dir, "static", "app.js"), encoding="utf-8").read()
    check("T115 表单含 PAT 密码框", 'id="acc-pat"' in html and 'type="password"' in html)
    check("T116 表单含「自动部署」开关", 'id="acc-autodeploy"' in html)
    check("T117 页面含部署进度面板", 'id="prov-panel"' in html and 'id="prov-steps"' in html)
    check("T118 前端提交带 pat/auto_deploy", "pat: pat" in appjs and "auto_deploy: autoDeploy" in appjs)
    check("T119 路由 GET /api/accounts/provision", ("GET", "/api/accounts/provision") in server.ROUTES)
    check("T120 后端具备 provision 关键函数",
          all(hasattr(server, n) for n in ("start_provision", "_prov_run", "sync_secrets_to_fork",
                                           "push_pool_config_to_hub", "ensure_fork", "enable_actions",
                                           "gh_secret_set", "verify_token_owner")))
    tdir = server.pool_token_dir()
    check("T121 PAT 存放目录在 .tools/pool 下",
          tdir.replace("\\", "/").endswith("/.tools/pool"), tdir)

    # PAT 绝不写进 pool-config.json / 响应体
    tmpcfg2 = os.path.join(tmpdir, "pool-cfg2.json")
    with open(tmpcfg2, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "accounts": []}, f)
    real_pc2 = server.CONFIG.get("pool_config")
    server.CONFIG["pool_config"] = tmpcfg2
    try:
        code, body, _ = req(base, "/api/accounts/add", "POST",
                            {"owner": "acctP", "repo": "cloud-rdp", "token_secret": "POOL_TOKEN_9",
                             "pat": "ghp_SUPERSECRET_XYZ", "auto_deploy": False})
        d = json.loads(body)
        check("T122 add(带 PAT, 不自动部署) 200/ok", code == 200 and d.get("ok") is True, body[:200])
        check("T123 未自动部署 → 无 job_id",
              not d.get("auto_deploy") and not d.get("job_id"), str(d.get("job_id")))
        raw = open(tmpcfg2, encoding="utf-8").read()
        check("T124 PAT 未写入 pool-config.json", "ghp_SUPERSECRET_XYZ" not in raw)
        check("T125 PAT 未出现在响应体里", "ghp_SUPERSECRET_XYZ" not in body)

        # 自动部署：offline 下 PAT 校验必然失败 → 任务快速失败，但接口仍 200 且带 job_id
        code, body, _ = req(base, "/api/accounts/add", "POST",
                            {"owner": "acctQ", "repo": "cloud-rdp", "token_secret": "POOL_TOKEN_10",
                             "pat": "ghp_FAKE", "auto_deploy": True})
        d = json.loads(body)
        check("T126 add(自动部署) 200 且带 job_id",
              code == 200 and d.get("auto_deploy") and bool(d.get("job_id")), body[:200])
        jid = d.get("job_id") or ""
        code, body, _ = req(base, "/api/accounts/provision?id=" + jid)
        dj = json.loads(body)
        check("T127 部署进度可查", code == 200 and dj.get("ok") is True and dj["job"]["id"] == jid)
        time.sleep(0.8)
        code, body, _ = req(base, "/api/accounts/provision?id=" + jid)
        dj = json.loads(body)
        check("T128 offline 下任务失败且记录了 verify_pat 步骤",
              dj["job"]["status"] == "failed"
              and any(s["step"] == "verify_pat" for s in dj["job"]["steps"]),
              str(dj["job"].get("summary")))
        code, _, _ = req(base, "/api/accounts/provision?id=nope-123")
        check("T129 未知部署任务 → 404", code == 404, "code=%s" % code)

        # 部署中的 owner 判定：只有 status=running 才算（前端据此显示「部署中…」而非「缺失」）
        with server._PROVISION_LOCK:
            server._PROVISION_JOBS["prov-fake-run"] = {"owner": "acctRun", "status": "running"}
            server._PROVISION_JOBS["prov-fake-done"] = {"owner": "acctDone", "status": "done"}
        try:
            po = server._provisioning_owners()
            check("T131b 只有 running 的 owner 算「部署中」", po == {"acctRun"}, str(po))
        finally:
            with server._PROVISION_LOCK:
                server._PROVISION_JOBS.pop("prov-fake-run", None)
                server._PROVISION_JOBS.pop("prov-fake-done", None)
    finally:
        if real_pc2 is None:
            server.CONFIG.pop("pool_config", None)
        else:
            server.CONFIG["pool_config"] = real_pc2
        server.clear_cache()

    wf_yaml = server._sync_wf_yaml("acctZ/cloud-rdp", "POOL_TOKEN_1")
    check("T130 _sync_wf_yaml 含目标仓库与 PAT Secret 引用",
          "TARGET: acctZ/cloud-rdp" in wf_yaml
          and "GH_TOKEN: ${{ secrets.POOL_TOKEN_1 }}" in wf_yaml
          and all(("S_%s: ${{ secrets.%s }}" % (s, s)) in wf_yaml for s in server._SYNC_SECRETS))
    check("T131 _prov_summary 统计失败步",
          "失败" in server._prov_summary({"steps": [{"step": "fork", "ok": False}]})
          and "成功" in server._prov_summary({"steps": [{"step": "fork", "ok": True}]}))

    # ---------------- 用户数据完整性：Edge / WorkBuddy 快照与恢复 ----------------
    # 背景：第 10 步（后台重装软件）过去只跑 winget，不恢复任何用户数据；
    # 而快照清单里 WorkBuddy 路径写的是 .workbuddy-ai（本机不存在）→ 静默零还原，
    # Edge 的 Login Data（已存密码）也从没被校验过。以下断言把「抓什么 / 校验什么」钉死。
    print("[用户数据 Edge/WorkBuddy]")
    repo_dir = os.path.dirname(wb_dir)
    sc = json.loads(open(os.path.join(repo_dir, "scripts", "snapshot-config.json"),
                         encoding="utf-8-sig").read())
    sc_files = sc.get("files") or {}
    sc_dirs = [str(x) for x in (sc_files.get("dirs") or [])]

    def _has_dir(frag):
        return any(frag in d for d in sc_dirs)

    check("T132 快照清单含 .workbuddy（当前真实用户数据目录）", _has_dir("\\.workbuddy"),
          "dirs=%d" % len(sc_dirs))
    check("T133 快照清单含 WorkBuddy 安装目录",
          _has_dir("AppData\\Local\\Programs\\WorkBuddy"))
    check("T134 快照清单含 WorkBuddy 运行数据与配置",
          _has_dir("AppData\\Local\\WorkBuddy") and _has_dir("AppData\\Roaming\\WorkBuddy"))

    noex = [str(x) for x in (sc_files.get("noExcludeDirs") or [])]
    wb_dirs = [d for d in sc_dirs if "workbuddy" in d.lower()]
    noex_missing = [d for d in wb_dirs if d not in noex]
    check("T135 noExcludeDirs 覆盖全部 WorkBuddy 目录（保住 Electron 缓存）",
          len(wb_dirs) >= 5 and not noex_missing,
          "wb_dirs=%d missing=%s" % (len(wb_dirs), noex_missing))
    check("T136 files.excludePaths 存在且为列表（按绝对路径精确排除，默认空）",
          isinstance(sc_files.get("excludePaths"), list))

    udt = (sc.get("restore") or {}).get("userDataTargets") or []
    udt_names = [str(t.get("name", "")) for t in udt]
    check("T137 restore.userDataTargets 6 个目标", len(udt) == 6, "n=%d" % len(udt))
    edge_t = [t for t in udt if "Edge" in str(t.get("name", ""))]
    check("T138 含 Edge 浏览器目标", len(edge_t) == 1, str(udt_names))
    if edge_t:
        reqd = [str(r) for r in (edge_t[0].get("required") or [])]
        check("T139 Edge 必检项含 History（浏览记录）", "Default\\History" in reqd, str(reqd))
        check("T140 Edge 必检项含 Login Data（本地保存的密码）",
              "Default\\Login Data" in reqd, str(reqd))
        check("T141 Edge 必检项含 Preferences（含下载位置等设置）",
              "Default\\Preferences" in reqd, str(reqd))
    check("T142 userDataTargets 覆盖 WorkBuddy 用户数据/安装/运行/配置",
          sum(1 for n in udt_names if n.startswith("WorkBuddy")) >= 5, str(udt_names))

    ud_lib = os.path.join(repo_dir, "scripts", "userdata-lib.ps1")
    check("T143 存在共享库 userdata-lib.ps1", os.path.isfile(ud_lib))
    ud_txt = open(ud_lib, encoding="utf-8-sig").read() if os.path.isfile(ud_lib) else ""
    check("T144 userdata-lib 导出 Invoke-UserDataVerifyAndRepair",
          "function Invoke-UserDataVerifyAndRepair" in ud_txt)
    check("T145 userdata-lib 含用户名迁移兜底（精确路径找不到时按尾部再找）",
          "Find-UDSnapshotDir" in ud_txt and "Users" in ud_txt)
    _rc_line = [ln for ln in ud_txt.splitlines() if "$rc = @(" in ln]
    check("T145b userdata-lib 补漏为「只补不删」（robocopy 参数里无 /PURGE）",
          len(_rc_line) == 1 and "/PURGE" not in _rc_line[0], str(_rc_line)[:160])

    reinstall_txt = open(os.path.join(repo_dir, "scripts", "reinstall-apps.ps1"),
                         encoding="utf-8-sig").read()
    check("T146 第 10 步 dot-source userdata-lib.ps1",
          "userdata-lib.ps1" in reinstall_txt and ". $userDataLib" in reinstall_txt)
    check("T147 第 10 步调用校验+补漏（-Quiesce，写 apps-status.json）",
          "Invoke-UserDataVerifyAndRepair" in reinstall_txt and "-Quiesce" in reinstall_txt
          and "userData" in reinstall_txt)
    check("T147b 第 10 步支持 -SkipUserData 开关", "-SkipUserData" in reinstall_txt)

    restore_txt = open(os.path.join(repo_dir, "scripts", "restore-snapshot.ps1"),
                       encoding="utf-8-sig").read()
    check("T148 restore-snapshot dot-source userdata-lib.ps1（口径与第 10 步同源）",
          ". $userDataLib" in restore_txt)
    check("T149 restore 取证透出 USERDATA_RESTORE（并保留 EDGE_RESTORE/WBAI_RESTORE）",
          "USERDATA_RESTORE=" in restore_txt and "EDGE_RESTORE=" in restore_txt
          and "WBAI_RESTORE=" in restore_txt)
    check("T149b restore 取证传 -Stage/-ConfigPath",
          "-Stage $Stage -ConfigPath $ConfigPath" in restore_txt)

    backup_txt = open(os.path.join(repo_dir, "scripts", "backup-snapshot.ps1"),
                      encoding="utf-8-sig").read()
    check("T150 backup-snapshot 支持 excludePaths（按绝对路径排除子目录）",
          "excludePaths" in backup_txt and "ExcludeDirsAbs" in backup_txt)

    wf_txt = open(os.path.join(repo_dir, ".github", "workflows", "windows-rdp.yml"),
                  encoding="utf-8").read()
    check("T151 工作流第 10 步名含「恢复 Edge/WorkBuddy 用户数据」",
          "后台重装软件 + 恢复 Edge/WorkBuddy 用户数据" in wf_txt)
    check("T152 ENV READY 汇总读 USERDATA_RESTORE / _DETAIL",
          "USERDATA_RESTORE" in wf_txt and "USERDATA_RESTORE_DETAIL" in wf_txt)

    # ---------------- 数据/快照还原可靠性（acc-1 事故） ----------------
    # 背景：acc-1（100.77.250.79）开机后没有从 139 云盘拉取数据，界面却显示「已同步」。
    # 根因：sync-down.ps1 只凭 rclone 退出码 3/4 就判定「远端为空」→ 一次 5 秒 DNS 抖动
    # （AList 把 PROPFIND 打成 404，rclone 同样映射成 3）也会被当成 EMPTY，机器空着手起来，
    # 随后自己的 sync-up 还会在 139 根目录 mkdir 出一个幽灵目录、并可能覆盖好快照。
    # 修复：新增共享分类库 remote-lib.ps1（OK / EMPTY / TRANSIENT / AUTH），
    # 一律「先探后拉」，探不通绝不写远端。以下断言把这条铁律钉死。
    print("[数据还原可靠性 remote-lib]")
    rl = os.path.join(repo_dir, "scripts", "remote-lib.ps1")
    check("T153 存在共享分类库 remote-lib.ps1", os.path.isfile(rl))
    rl_txt = open(rl, encoding="utf-8-sig").read() if os.path.isfile(rl) else ""
    for fn in ("Get-RcloneErrorKind", "Get-RemoteProbe", "Resolve-RemoteVerdict",
               "Test-AlistRemoteReachable", "Set-RestoreStatus", "Get-RestoreStatusValue"):
        check("T154 remote-lib 导出 %s" % fn, ("function %s" % fn) in rl_txt)
    check("T155 remote-lib 四态判定 OK/EMPTY/TRANSIENT/AUTH 齐全",
          all(("'%s'" % k) in rl_txt for k in ("OK", "EMPTY", "TRANSIENT", "AUTH")))
    check("T156 Set-RestoreStatus 按作用域合并（data/snapshot 不互相覆盖）",
          "$obj[$Scope]" in rl_txt and "[System.IO.File]::Move" in rl_txt)

    sd_txt = open(os.path.join(repo_dir, "scripts", "sync-down.ps1"),
                  encoding="utf-8-sig").read()
    check("T157 sync-down dot-source remote-lib.ps1", "remote-lib.ps1" in sd_txt)
    check("T158 sync-down 用 Resolve-RemoteVerdict 分类（不再只看退出码）",
          "Resolve-RemoteVerdict" in sd_txt)
    check("T159 sync-down 区分 TRANSIENT（网络抖动绝不写本地）", "TRANSIENT" in sd_txt)
    check("T160 sync-down 支持 -Repull（保活循环自愈重拉）", "[switch]$Repull" in sd_txt)

    su_txt = open(os.path.join(repo_dir, "scripts", "sync-up.ps1"),
                  encoding="utf-8-sig").read()
    check("T161 sync-up 守卫 A：远端不可达则拒绝 mkdir/copy（防 139 根幽灵目录）",
          "Test-AlistRemoteReachable" in su_txt and "exit 0" in su_txt)
    check("T162 sync-up 守卫 B：读 data 恢复状态，TRANSIENT/FAILED/PENDING 不推送（-Force 可覆盖）",
          "Get-RestoreStatusValue" in su_txt and "TRANSIENT" in su_txt and "-Force" in su_txt)

    bs_txt = open(os.path.join(repo_dir, "scripts", "backup-snapshot.ps1"),
                  encoding="utf-8-sig").read()
    check("T163 backup-snapshot -Push 有守卫 A/B（防 sync 覆盖 139 上的好快照）",
          "Test-AlistRemoteReachable" in bs_txt and "Get-RestoreStatusValue" in bs_txt
          and "SNAPSHOT_PUSH" in bs_txt)

    check("T164 工作流有「跟随上游 hub 同步脚本」步骤（fork 自愈，永不跑旧逻辑）",
          "跟随上游 hub 同步脚本" in wf_txt and "codeload.github.com" in wf_txt)
    check("T165 工作流保活循环含自愈（restore-status.json → -Repull / 快照 pending）",
          "restore-status.json" in wf_txt and "-Repull" in wf_txt
          and "snapshot-restore-pending.txt" in wf_txt)
    check("T166 ENV READY 打印「数据恢复 / 整机还原」状态",
          "数据恢复" in wf_txt and "整机还原" in wf_txt)

    co_txt = open(os.path.join(repo_dir, ".github", "workflows", "pool-coordinator.yml"),
                  encoding="utf-8").read()
    check("T167 协调器有 hub-only 守卫（fork 的定时运行跳过，避免多头指挥）",
          "is_hub" in co_txt and "GITHUB_REPOSITORY" in co_txt)

    # ---------------- 工作台透出「数据/快照恢复状态」 ----------------
    print("[工作台恢复状态]")
    check("T168 server.py 版本 1.5.0", server.VERSION == "1.5.0", server.VERSION)
    check("T169 存在 read_restore_status()", callable(getattr(server, "read_restore_status", None)))
    check("T170 restore_kind 口径与脚本侧一致",
          (server.restore_kind("OK") == "ok" and server.restore_kind("PARTIAL") == "ok"
           and server.restore_kind("EMPTY") == "empty" and server.restore_kind("SKIPPED") == "empty"
           and server.restore_kind("TRANSIENT") == "bad" and server.restore_kind("PENDING") == "bad"
           and server.restore_kind("FAILED") == "bad" and server.restore_kind("AUTH") == "bad"
           and server.restore_kind("") == "none"),
          server.restore_kind("TRANSIENT"))
    check("T171 machine_restore_summary：坏状态优先于好状态",
          server.machine_restore_summary(
              {"restore": {"data": {"status": "OK"},
                           "snapshot": {"status": "TRANSIENT"}}})["kind"] == "bad")
    check("T172 machine_detail 返回含 restore 字段（默认空也带）",
          "restore" in server.machine_detail("0.0.0.0", False))

    code, body, _ = req(base, "/api/overview")
    stats_d = (json.loads(body).get("stats") or {})
    check("T173 /api/overview stats 含 machines_data_bad / machines_snapshot_bad",
          "machines_data_bad" in stats_d and "machines_snapshot_bad" in stats_d,
          str(sorted(stats_d.keys())))

    idx_txt = open(os.path.join(wb_dir, "static", "index.html"), encoding="utf-8").read()
    check("T174 index.html 机器表新增「恢复」列", ">恢复</th>" in idx_txt)
    app_txt = open(os.path.join(wb_dir, "static", "app.js"), encoding="utf-8").read()
    check("T175 app.js 有 restoreBadge 并渲染进机器表",
          "function restoreBadge" in app_txt and "restoreBadge(m.restore)" in app_txt)

    # ---------------- 收尾 ----------------
    httpd.shutdown()
    httpd.server_close()

    print("\n" + "=" * 56)
    print("  结果：%d PASS / %d FAIL" % (PASS, FAIL))
    if FAILURES:
        print("  失败项：" + ", ".join(FAILURES))
    print("=" * 56)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
