#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""智能体工作台 —— 离线自测（零依赖）。

不联网、不碰真机：把 server.py 以 offline 模式在随机端口跑起来，
逐个打 API，校验状态码与关键字段；再单测几个纯函数。

    python workbench/selftest.py
"""
from __future__ import annotations

import base64
import json
import os
import sys
import tempfile
import threading
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
    check("T02 index 含标题", "智能体工作台" in body)
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
    check("T07 health 有 version/repo", bool(d.get("version")) and bool(d.get("repo")))
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
                                       "token_state", "alive_count", "last_run", "source"))
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

        # ---------------- 新增账号 API ----------------
        print("[API accounts/add]")
        code, body, _ = req(base, "/api/accounts/add", "POST",
                            {"owner": "acct3", "repo": "cloud-rdp", "token_secret": "POOL_TOKEN_3"})
        d = json.loads(body)
        check("T69 add 200/ok", code == 200 and d.get("ok") is True, body[:200])
        check("T70 add 自动生成 id", (d.get("id") or "").startswith("acc-"), str(d.get("id")))
        with open(tmpcfg, encoding="utf-8") as f:
            saved = json.load(f)
        check("T71 已写回配置文件", any(a.get("owner") == "acct3" for a in saved.get("accounts") or []))
        check("T72 add 返回 Secret 提示", "POOL_TOKENS" in (d.get("hint") or ""))

        code, _, _ = req(base, "/api/accounts/add", "POST",
                         {"owner": "acct3", "repo": "cloud-rdp", "token_secret": "X"})
        check("T73 重复 owner → 409", code == 409, "code=%s" % code)
        code, _, _ = req(base, "/api/accounts/add", "POST",
                         {"owner": "", "repo": "r", "token_secret": "S"})
        check("T74 空 owner → 400", code == 400, "code=%s" % code)
        code, _, _ = req(base, "/api/accounts/add", "POST",
                         {"owner": "acct9", "repo": "r", "token_secret": "1bad"})
        check("T75 非法 Secret 名 → 400", code == 400, "code=%s" % code)
        code, _, _ = req(base, "/api/accounts/add", "POST",
                         {"owner": "acct9", "repo": "r", "token_secret": "OK_NAME", "id": "acc-1"})
        check("T76 重复 id → 409", code == 409, "code=%s" % code)
    finally:
        server.get_pool_state = real_pool
        server.get_secret_names = real_secrets
        if real_pc is None:
            server.CONFIG.pop("pool_config", None)
        else:
            server.CONFIG["pool_config"] = real_pc
        server.clear_cache()

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
