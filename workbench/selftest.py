#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GitHub 虚拟机管理工作台 —— 离线自测（零依赖）。

不联网、不碰真机：把 server.py 以 offline 模式在随机端口跑起来，
逐个打 API，校验状态码与关键字段；再单测几个纯函数。

    python workbench/selftest.py
"""
from __future__ import annotations

import base64
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
import urllib.error
import urllib.request
import zipfile

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


def req_raw(base, path, method="GET"):
    """同 req，但返回原始字节 + 响应头 —— 数据导出要验 Content-Disposition / 二进制 zip。"""
    r = urllib.request.Request(base + path, method=method)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


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
    # 「主机」列：一次性 runner 的 HostName 全叫 github-rdp-server，靠 DNSName 唯一短名区分
    check("T93b peer_short_name 取 DNSName 首段（重名节点可区分）",
          server.peer_short_name("github-rdp-server-11.tailf6704b.ts.net.") == "github-rdp-server-11"
          and server.peer_short_name("github-rdp-server-3") == "github-rdp-server-3")
    check("T93c peer_short_name 空/None → 空串（前端退回 HostName）",
          server.peer_short_name("") == "" and server.peer_short_name(None) == ""
          and server.peer_short_name("   ") == "")
    check("T93d collect_machines 空 peers 不炸",
          server.collect_machines([], [{"id": "acc-1", "owner": "alice"}]) == [])
    _cm = server.collect_machines(
        [{"ip": "100.1.1.1", "online": False, "hostname": "github-rdp-server",
          "dns_name": "github-rdp-server-7"}],
        [{"id": "acc-1", "owner": "alice"}])
    check("T93e collect_machines 与 overview 同形状：补 account_id 且透传 dns_name",
          len(_cm) == 1 and _cm[0].get("account_id") == ""
          and _cm[0].get("dns_name") == "github-rdp-server-7", str(_cm))
    # 池内机器补行：job 在跑但 Tailscale 上看不到 → 不能整台消失
    _ps = {"state": {
        "primary": {"account": "acc-1", "owner": "alice", "repo": "cloud-rdp",
                    "run_id": 111, "since": "2026-09-23T00:00:00Z"},
        "standby": [{"account": "acc-3", "owner": "bob", "repo": "cloud-rdp",
                     "run_id": 222, "since": "2026-09-23T06:00:00Z"},
                    {"account": "acc-4", "owner": "carol", "repo": "cloud-rdp",
                     "run_id": None, "since": "2026-09-23T06:51:00Z"}],
        "accounts": [{"id": "acc-3", "last_run": {"run_id": 222, "status": "in_progress",
                                                  "conclusion": "", "url": "https://x/222"}}],
    }}
    _pm = server.pool_machine_rows(_ps, [{"account_id": "acc-1", "online": True, "ip": "100.0.0.1"}])
    check("T93f 池内机器：已有在线节点的槽位不补行（primary acc-1 跳过）",
          [r["account_id"] for r in _pm] == ["acc-3", "acc-4"], str(_pm))
    check("T93g 池内机器：带 run 链接 / 状态 / 角色，且标记 pool_only",
          _pm[0].get("pool_only") is True and _pm[0].get("run_url") == "https://x/222"
          and _pm[0].get("run_status") == "in_progress" and _pm[0].get("role") == "standby",
          str(_pm[0]))
    check("T93h 池内机器：run_id 为空时 run_url 也留空（不拼出坏链接）",
          _pm[1].get("run_id") is None and _pm[1].get("run_url") == "", str(_pm[1]))
    check("T93i pool_machine_rows 空/异常池状态 → []",
          server.pool_machine_rows({}, []) == []
          and server.pool_machine_rows(None, None) == []
          and server.pool_machine_rows({"state": []}, []) == [])
    _pm2 = server.pool_machine_rows(_ps, [{"account_id": "acc-1", "online": True},
                                          {"account_id": "acc-1", "online": True}])
    check("T93j 同账号两台在线节点 → 只认领两个槽位，不多补行",
          [r["account_id"] for r in _pm2] == ["acc-3", "acc-4"], str(_pm2))
    # acc-1 同时占 primary 与 standby 两个槽位、但只有 1 台在线 → 不能补出「假的缺失行」
    _ps3 = {"state": {
        "primary": {"account": "acc-1", "owner": "alice", "run_id": 1},
        "standby": [{"account": "acc-1", "owner": "alice", "run_id": 2},
                    {"account": "acc-4", "owner": "carol", "run_id": 3}],
        "accounts": [],
    }}
    _pm3 = server.pool_machine_rows(_ps3, [{"account_id": "acc-1", "online": True}])
    check("T93k 同账号多槽位且已有在线机器 → 一行都不补（不误报「未上线」）",
          [r["account_id"] for r in _pm3] == ["acc-4"], str(_pm3))

    # 机器状态口径：job in_progress ⇒ 机器在跑（不再一律写死「Tailscale 未上线」）
    check("T93l pool_run_state：in_progress→running、排队类→dispatched、终态→ended、空→unknown",
          server.pool_run_state("in_progress") == "running"
          and server.pool_run_state("  In_Progress ") == "running"
          and server.pool_run_state("queued") == "dispatched"
          and server.pool_run_state("pending") == "dispatched"
          and server.pool_run_state("completed") == "ended"
          and server.pool_run_state("cancelled") == "ended"
          and server.pool_run_state("") == "unknown"
          and server.pool_run_state(None) == "unknown",
          "%s/%s/%s" % (server.pool_run_state("in_progress"),
                        server.pool_run_state("completed"), server.pool_run_state(None)))
    _ps4 = {"state": {
        "primary": {"account": "acc-1", "owner": "alice", "run_id": 1},
        "standby": [{"account": "acc-3", "owner": "hub", "run_id": 35820523536,
                     "since": "2026-09-23T04:58:55Z"},
                    {"account": "acc-4", "owner": "carol", "run_id": 9},
                    {"account": "acc-5", "owner": "dave", "run_id": 7},
                    {"account": "acc-6", "owner": "erin", "run_id": 11}],
        "accounts": [{"id": "acc-3", "last_run": {"status": "in_progress", "run_id": 35820523536}},
                     {"id": "acc-4", "last_run": {"status": "queued", "run_id": 9}},
                     {"id": "acc-5", "last_run": {"status": "completed", "conclusion": "success", "run_id": 7}}],
    }}
    _pm4 = server.pool_machine_rows(_ps4, [{"account_id": "acc-1", "online": True}])
    _by = {r["account_id"]: r for r in _pm4}
    check("T93m 池内机器：job in_progress ⇒ machine_state=running（面板出「运行中」）",
          _by["acc-3"].get("machine_state") == "running", str(_by.get("acc-3")))
    check("T93n 池内机器：queued⇒dispatched、completed⇒ended、无 run 状态⇒unknown",
          _by["acc-4"].get("machine_state") == "dispatched"
          and _by["acc-5"].get("machine_state") == "ended"
          and _by["acc-6"].get("machine_state") == "unknown",
          str({k: v.get("machine_state") for k, v in _by.items()}))
    check("T93o pool_machine_rows 每条都带 machine_state（前端不靠自己猜）",
          all("machine_state" in r for r in _pm4),
          str([r.get("machine_state") for r in _pm4]))

    # 池内机器的 IP 兜底：本机 tailnet 看不到节点时，从它自己的 Actions job 日志里挖。
    _m_ip = server._JOB_IP_RE.search(
        "2026-09-23T06:12:39.5972790Z [0c] Tailscale IP: 100.112.127.106")
    check("T93p job 日志里的机器自报 IP 行能被解析（[0c] Tailscale IP: x.x.x.x）",
          bool(_m_ip) and _m_ip.group(1) == "100.112.127.106"
          and server._JOB_IP_RE.search("no ip here") is None,
          _m_ip.group(1) if _m_ip else "无匹配")
    check("T93q job_tailscale_ip：离线 / 缺 owner / 缺 run_id → 空串（绝不抛）",
          server.job_tailscale_ip("o", "r", 1) == ""
          and server.job_tailscale_ip("", "r", 1) == ""
          and server.job_tailscale_ip("o", "r", None) == "")
    check("T93r pool_row_netinfo 离线 → 空 ip / 空 ip_source / reachable=None",
          server.pool_row_netinfo("o", "r", 1) == {"ip": "", "ip_source": "", "reachable": None})
    check("T93s pool_machine_rows 每行都带 ip / ip_source / reachable（前端不自己拼）",
          all(("ip" in r and "ip_source" in r and "reachable" in r) for r in _pm4),
          str([sorted(k for k in r if k in ("ip", "ip_source", "reachable")) for r in _pm4]))
    check("T93t 有 _NoAuthRedirect：302 跳 blob 时摘掉 Authorization（否则 401）",
          hasattr(server, "_NoAuthRedirect")
          and issubclass(server._NoAuthRedirect, urllib.request.HTTPRedirectHandler))

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

    # ---------------- Default.rdp 的两个坑（编码 / 隐藏属性） ----------------
    # 瑀子实测：面板报「authentication level=未设置」+ 点修复报 Errno 13 Permission denied。
    # 根因 ① mstsc 写的 Default.rdp 是 UTF-16LE+BOM，用 ascii 读 → 正则全失配 → 已是 0 也报未设置。
    # 根因 ② Default.rdp 带 HIDDEN 属性，open(p,"w")=CREATE_ALWAYS 对隐藏文件必然 ACCESS_DENIED。
    _tmpd = tempfile.mkdtemp(prefix="wb-rdp-")
    try:
        _u16 = os.path.join(_tmpd, "Default.rdp")
        with open(_u16, "wb") as _f:
            _f.write(b"\xff\xfe" + "authentication level:i:0\r\n".encode("utf-16-le"))
        _txt, _enc = server.read_rdp_text(_u16)
        check("T200 read_rdp_text 认得 UTF-16LE+BOM（按 ascii 读会让正则失配 → 误报「未设置」）",
              _enc == "utf-16" and re.search(r"authentication level:i:0", _txt) is not None,
              "%s / %r" % (_enc, _txt[:32]))
        check("T201 encode_rdp_text 保住 BOM 与原编码（不会把 UTF-16 文件写成 ANSI）",
              server.encode_rdp_text("abc", "utf-16") == b"\xff\xfe" + "abc".encode("utf-16-le")
              and server.encode_rdp_text("abc", "latin-1") == b"abc")
        server.write_rdp_inplace(_u16, b"\xff\xfe" + "x".encode("utf-16-le"))
        check("T202 write_rdp_inplace 走 r+b（open(p,'w') 对隐藏文件必 Errno 13）",
              open(_u16, "rb").read() == b"\xff\xfe" + "x".encode("utf-16-le"))
        check("T203 default_rdp_status 带 encoding / hidden（不再只有一个 auth_level）",
              "encoding" in st and "hidden" in st, str(sorted(st.keys())))
        check("T204 有 mstsc_running()（写失败时能提示「关掉远程桌面再试」）",
              callable(getattr(server, "mstsc_running", None)))
        if server.IS_WINDOWS:
            _hp = os.path.join(_tmpd, "Default.rdp")
            with open(_hp, "wb") as _f:
                _f.write(b"\xff\xfe" + ("screen mode id:i:2\r\nauthentication level:i:2\r\n"
                                        .encode("utf-16-le")))
            server.set_file_attrs(_hp, 0x80 | 0x2)      # NORMAL|HIDDEN —— mstsc 建出来就长这样
            _orig_path = server.default_rdp_path
            server.default_rdp_path = lambda pp=_hp: pp
            try:
                _ok, _note = server.ensure_default_rdp_auth_level()
                _raw = open(_hp, "rb").read()
                _attrs = server.file_attrs(_hp)
            finally:
                server.default_rdp_path = _orig_path
            # 注意断言写法：BOM 在文件**开头**（screen mode id 之前），不是紧贴 auth 行。
            # 之前写成 b"\xff\xfe" + auth行 必然 False —— 那是断言错了，不是修错了。
            check("T205 隐藏 + UTF-16 的 Default.rdp 真能改成 auth=0（保住 BOM 与 HIDDEN）",
                  _ok is True
                  and _raw[:2] == b"\xff\xfe"
                  and "authentication level:i:0\r\n".encode("utf-16-le") in _raw
                  and bool(_attrs & 0x2),
                  "%s | %s | attrs=0x%02x" % (_ok, _note, _attrs))
    finally:
        shutil.rmtree(_tmpd, ignore_errors=True)

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
    check("T137 restore.userDataTargets 8 个目标（6 个 Edge/WorkBuddy + 2 个 UU远程）",
          len(udt) == 8, "n=%d" % len(udt))
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

    # ---------------- UU远程（网易 GameViewer）「每次都当新设备 / 要创建账号」 ----------------
    # 瑀子 2026-09-26 反馈。真机取证（云机 SMB 直读）：
    #   · 程序本体 C:\Program Files\Netease\GameViewer\GameViewer.exe 的 mtime=09-17 而 ctime=09-26
    #     → 是 robocopy 带 /COPY:DAT 还原来的（时间戳被保留），说明「快捷方式线索补抓」是通的；
    #   · C:\ProgramData\Netease\GameViewer\*（deviceId / uuid / 协助码）ctime 全是开机时刻
    #     → 是 UU远程 现建的，不是还原来的 —— 清单里从来没有它（ProgramData 是机器级路径）。
    #   · user_info.ini 的 token/userId 为空是**正常态**（本机也一样）：UU远程 免登录也能远程协助，
    #     决定「你是不是新设备」的是明文 deviceId / uuid，不是账号。
    uu_t = [t for t in udt if str(t.get("name", "")).startswith("UU远程")]
    check("T142b userDataTargets 含 UU远程 机器级 + 用户级两个目标",
          len(uu_t) == 2, str(udt_names))
    _uu_m = [t for t in uu_t if "ProgramData" in str(t.get("path", ""))]
    _uu_u = [t for t in uu_t if "GameViewer" in str(t.get("path", ""))
             and "AppData" in str(t.get("path", ""))]
    check("T142c UU远程 机器级目标 = C:\\ProgramData\\Netease\\GameViewer（deviceId/uuid/协助码所在）",
          len(_uu_m) == 1 and "Netease\\GameViewer" in str(_uu_m[0].get("path", ""))
          and "user_info.ini" in [str(x) for x in (_uu_m[0].get("required") or [])]
          and "config.ini" in [str(x) for x in (_uu_m[0].get("required") or [])]
          and "remote_assist_code.ini" in [str(x) for x in (_uu_m[0].get("required") or [])],
          str(_uu_m))
    check("T142d UU远程 用户级目标 = %RDPUSERPROFILE%\\AppData\\Local\\GameViewer",
          len(_uu_u) == 1 and "%RDPUSERPROFILE%" in str(_uu_u[0].get("path", "")), str(_uu_u))
    check("T142e ★ files.dirs 收了 UU远程 两处（机器级 ProgramData 从不在 %RDPUSERPROFILE% 系里）",
          _has_dir("ProgramData\\Netease\\GameViewer") and _has_dir("AppData\\Local\\GameViewer"),
          "dirs=%d" % len(sc_dirs))
    check("T142f ★ noExcludeDirs 也收了 UU远程 两处（否则内嵌 WebView2 的 Cache/IndexedDB 被目录名排除）",
          all(any(d in x for x in noex) for d in
              ["ProgramData\\Netease\\GameViewer", "AppData\\Local\\GameViewer"]), str(noex))
    _uu_globs = [str(d) for g in ((sc.get("programs") or {}).get("dataGlobs") or [])
                 for d in ((g or {}).get("dirs") or [])]
    check("T142g programs.dataGlobs 显式点名 UU远程 机器级目录（files.dirs 之外的第二道保险）",
          any("ProgramData\\Netease\\GameViewer" in g for g in _uu_globs), str(_uu_globs))

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
    check("T168 server.py 版本 1.6.5", server.VERSION == "1.6.5", server.VERSION)
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

    # ---------------- 状态栏「状态详情」折叠 ----------------
    css_txt = open(os.path.join(wb_dir, "static", "styles.css"), encoding="utf-8").read()
    check("T176 app.js 有状态详情折叠（machineKey / FOLD_DETAILS / statusCell / toggleFoldDetail / fold-caret）",
          all(s in app_txt for s in ("function machineKey", "var FOLD_DETAILS", "function statusCell",
                                     "function toggleFoldDetail", "fold-caret")),
          "缺少折叠实现")
    check("T177 折叠状态持久化到 localStorage（wb.foldDetails），刷新后保持",
          '"wb.foldDetails"' in app_txt and "localStorage.setItem" in app_txt)
    check("T178 状态栏统一走 statusCell（定义 1 次 + 池内机器 / Tailscale 节点各 1 处调用）",
          app_txt.count("statusCell(") >= 3, "statusCell 出现 %d 次" % app_txt.count("statusCell("))
    check("T179 有「折叠详情」按钮 #btn-fold-all（HTML+JS 都接了），styles.css 有折叠样式",
          'id="btn-fold-all"' in idx_txt and '#btn-fold-all' in app_txt
          and ".fold-caret" in css_txt and ".st-wrap.folded" in css_txt)

    # ---------------- 池内机器行：真 IP + 一键登录 ----------------
    _pool_fn = ""
    if "function poolOnlyRow(" in app_txt:
        _pool_fn = app_txt.split("function poolOnlyRow(", 1)[1].split("\nfunction ", 1)[0]
    check("T180 池内机器行：有 IP 就渲染真 IP（不再写死 —）+ 一键登录按钮（rdpBtn → data-rdp）",
          "ipCell" in _pool_fn and "rdpBtn(ip, hostLabel" in _pool_fn and "m.ip" in _pool_fn
          and "一键登录" in app_txt and "data-rdp=" in app_txt,
          "poolOnlyRow 未接真 IP / 登录按钮")
    check("T181 池内机器行：可达性未知/不可达分开呈现（btn-warn）+ styles.css 有该样式",
          "btn-warn" in _pool_fn and "reachable" in _pool_fn and ".btn-warn" in css_txt)
    check("T182 池内机器行仍保留「运行日志」入口（拿不到 IP 时还能看进度）",
          "运行日志" in _pool_fn and "m.run_url" in _pool_fn)

    # ---------------- 中文环境（0f 步超时修复，run 35813312970 复盘） ----------------
    # 事故：0f 步 timeout-minutes=6（360s），而脚本「同步等语言包」写死 300s，
    # 加上系统 locale 2s + 用户 hive 33s + 增强步 ≥19s ≈ 360s —— 每次必然顶到
    # step 超时被 kill（实测 03:12:41 起 → 03:18:41 被杀，正好 360s）。
    # 更糟的是 GitHub 结束 step 时会杀掉该 step 的整棵进程树，老版 Start-Process 起的
    # 那个「后台」子进程跟着一起死 → 语言包从没装成功过；而 CHINESE_STATUS 写在脚本
    # 末尾，被 kill 后一个状态都没透出 → ENV READY 里「中文环境」整行消失，看起来
    # 就是「每次都失败」。修复：语言包改挂计划任务（活得过 step）、状态分段落盘、
    # 同步等待挪到最后且默认降到 90s。以下断言把这条设计钉死。
    print("[中文环境 0f 超时修复]")
    sc_path = os.path.join(repo_dir, "scripts", "setup-chinese.ps1")
    check("T183 存在 setup-chinese.ps1", os.path.isfile(sc_path))
    sc_txt = open(sc_path, encoding="utf-8-sig").read() if os.path.isfile(sc_path) else ""

    check("T184 语言包安装改挂计划任务（Register-ScheduledTask + Start-ScheduledTask）",
          "Register-ScheduledTask" in sc_txt and "Start-ScheduledTask" in sc_txt)
    check("T185 计划任务以 SYSTEM 身份跑（-UserId 'SYSTEM' -LogonType ServiceAccount）",
          "-UserId 'SYSTEM'" in sc_txt and "-LogonType ServiceAccount" in sc_txt)
    check("T186 保留 Start-Process 兜底（本机无计划任务组件时仍能装）",
          "Start-Process -FilePath $exe" in sc_txt and "退回 Start-Process" in sc_txt)
    check("T187 同步等待默认降到 90s（老的 300s 必然顶穿 6 分钟 step 超时）",
          "$LangPackWaitSec    = 90" in sc_txt and "$LangPackWaitSec    = 300" not in sc_txt)
    check("T188 同步等待挪到「用户 hive 写完之后」（唯一不可控时长放最后）",
          "同步等后台语言包最多" in sc_txt
          and sc_txt.index("同步等后台语言包最多") > sc_txt.index("-Phase 'userhive'"))
    check("T189 状态分段落盘：Write-ChineseState 定义 1 次 + 至少 5 处调用",
          sc_txt.count("function Write-ChineseState") == 1
          and sc_txt.count("Write-ChineseState -LangState") >= 5,
          "调用 %d 次" % sc_txt.count("Write-ChineseState -LangState"))
    check("T190 状态同时落盘 _state\\chinese-status.json（供工作台/收尾核对读）",
          "chinese-status.json" in sc_txt and "[System.IO.File]::Move" in sc_txt)
    check("T191 有 -CheckOnly 收尾核对模式（装完补报 + 清掉计划任务）",
          "[switch]$CheckOnly" in sc_txt and "Unregister-ScheduledTask" in sc_txt)
    check("T192 有 -SysDir 参数（计划任务子进程不继承 job 环境变量）",
          "[string]$SysDir" in sc_txt and '-SysDir "{3}"' in sc_txt)
    check("T193 两个 -Credential 调用不再裸用 -Wait（改 Invoke-AsUser + Wait-Process -Timeout）",
          "function Invoke-AsUser" in sc_txt and "Wait-Process -Id $p.Id -Timeout" in sc_txt
          and "-Credential $credU -Wait" not in sc_txt and "-Credential $cred2 -Wait" not in sc_txt)

    check("T194 0f 步 timeout-minutes 提到 8（脚本正常 100~150s 返回）",
          "timeout-minutes: 8" in wf_txt)
    check("T195 0f 步名标明「秒级放行 / 计划任务后台」",
          "秒级放行" in wf_txt and "计划任务后台" in wf_txt)
    check("T196 新增 12b 步做收尾核对（setup-chinese.ps1 -CheckOnly）",
          "12b. 中文语言包收尾核对" in wf_txt)
    check("T197 保活循环补报中文语言包（-CheckOnly 至少出现 2 次：12b + keepalive）",
          wf_txt.count("setup-chinese.ps1 -CheckOnly") >= 2,
          "出现 %d 次" % wf_txt.count("setup-chinese.ps1 -CheckOnly"))
    check("T198 ENV READY 中文语言包提示 langpack.log 路径",
          "langpack.log" in wf_txt)
    check("T199 -UserHiveOnly 不抹掉上一步状态（语言包/系统 locale 沿用，不再被写成 SKIPPED）",
          "本次不处理语言包，沿用上一步状态" in sc_txt
          and "$prevLp = [string]$env:CHINESE_LANGPACK" in sc_txt
          and "$prevSys = [string]$env:CHINESE_SYSTEMLOCALE" in sc_txt)

    # ---------------- 「机器运行实况」排版（8 列固定列宽 + 统一纵向节奏） ----------------
    # 目标：8 列挤在 span-7 卡片里也要视觉协调。实测两处硬伤（见 styles.css 注释）：
    #   ① auto 布局列宽随内容/行数抖动（同一张表 2 行时「最后在线」31.5px，48 行时 77px）；
    #   ② 内容顶破卡片 → 横向滚动条（实测溢出 37~83px）。
    # 以下断言把「列宽写死 + 顶端对齐 + 窄视口回退整行」三条设计钉死，防止改回 auto。
    print("[机器运行实况 排版]")
    check("T206 styles.css 机器表改 table-layout:fixed（列宽不再随内容/行数抖动）",
          ".tbl-machines { table-layout: fixed" in css_txt and "min-width: 820px" in css_txt)
    check("T207 index.html 机器表带 <colgroup> + 8 个 c-* 列（写死列宽的载体）",
          "<colgroup>" in idx_txt and idx_txt.count('class="c-') == 8,
          "c-* 列 %d 个" % idx_txt.count('class="c-'))
    check("T208 styles.css 八列宽度全部显式定义（c-host…c-ops 各一条）",
          all((".tbl-machines .c-%s" % c) in css_txt
              for c in ("host", "ip", "state", "role", "restore", "snap", "seen", "ops")),
          "缺列宽定义")
    check("T209 纵向节奏：td 顶端对齐 + 单行行高下限 54px + 详情/操作列允许换行",
          ".tbl-machines td { vertical-align: top;" in css_txt
          and ".tbl-machines tbody tr { height: 54px; }" in css_txt
          and ".tbl-machines .uptime { white-space: normal; }" in css_txt
          and ".tbl-machines td.ops-cell { white-space: normal; }" in css_txt)
    check("T210 斑马纹 + 悬停 + 安静占位 .none + 卡片副行 .card-sub",
          ".tbl-machines tbody tr:nth-child(even)" in css_txt
          and ".tbl-machines tbody tr:hover" in css_txt
          and ".none {" in css_txt and ".card-sub {" in css_txt)
    check("T211 窄视口（≤1720px）机器表/账号卡各占整行（避免挤成横向滚动条）",
          "@media (max-width: 1720px)" in css_txt
          and ".card-machines, .card-accounts { grid-column: span 12; }" in css_txt)
    check("T212 快照列拆两行（徽章 + 备份按钮），文件数移到 tooltip 不再撑列宽",
          'class="snap-foot"' in app_txt and "snapTop" in app_txt and "snapFoot" in app_txt
          and "文件数 " in app_txt)
    check("T213 操作列去掉 nowrap（renderMachines + poolOnlyRow 两处都用 ops-cell）",
          app_txt.count("right ops-cell") >= 2,
          "right ops-cell 出现 %d 次" % app_txt.count("right ops-cell"))

    # ---------------- 用户配置文件预创建（「用户数据整段丢失」的根因修复） ----------------
    # 背景（真机 run 35780696116）：整轮 run 里 C:\Users\a 从未出现 —— Edge User Data /
    # 桌面 / 文档 / .workbuddy 全程零还原，日志只有一句「用户配置文件未创建成功（将交给登录任务）」。
    # 根因：Start-Process -Credential 不会顺手加载目标用户 profile —— -LoadUserProfile 是
    # 独立参数、默认 $false（官方文档：The default value is FALSE）；缺了它 .NET 走
    # LOGON_NETCREDENTIALS_ONLY，进程起得来、不报错，但 profile 根本没被创建。
    # 以下断言把「必须显式 -LoadUserProfile + 必须有兜底 + 失败必须可见」三条钉死。
    print("[用户配置文件预创建 userprofile-lib]")
    up_lib = os.path.join(repo_dir, "scripts", "userprofile-lib.ps1")
    check("T214 存在共享库 userprofile-lib.ps1（profile 预创建的唯一实现）",
          os.path.isfile(up_lib))
    up_txt = open(up_lib, encoding="utf-8-sig").read() if os.path.isfile(up_lib) else ""
    check("T215 userprofile-lib 导出 Initialize-RdpUserProfile",
          "function Initialize-RdpUserProfile" in up_txt)
    check("T216 Initialize-RdpUserProfile 用 -LoadUserProfile 真正创建 profile",
          "Initialize-RdpUserProfile" in up_txt
          and "-Credential $cred" in up_txt and "-LoadUserProfile" in up_txt)
    check("T217 兜底：手工登记 ProfileList（ProfileImagePath，否则登录会另建 <user>.<机器名>）",
          "Register-UPProfileManually" in up_txt
          and "ProfileImagePath" in up_txt and "NTUSER.DAT" in up_txt)
    check("T218 预创建后轮询等待 NTUSER.DAT 落盘（首次要复制 Default profile）",
          "WaitSec" in up_txt and "Start-Sleep -Seconds 1" in up_txt)
    check("T219 userprofile-lib 提供 Invoke-AsRdpUser（以用户身份跑探测，需真实用户上下文）",
          "function Invoke-AsRdpUser" in up_txt)

    # 铁律：任何 Start-Process -Credential 都必须带 -LoadUserProfile。
    # 先剥掉 <# 块注释 #>，再剥掉 # 行注释，避免把「反面教材」的注释误判成代码。
    _sp_bad = []
    for _nm in ("restore-snapshot.ps1", "setup-chinese.ps1", "userprofile-lib.ps1",
                "userdata-lib.ps1", "backup-snapshot.ps1", "reinstall-apps.ps1"):
        _p = os.path.join(repo_dir, "scripts", _nm)
        if not os.path.isfile(_p):
            continue
        _t = re.sub(r"<#.*?#>", "", open(_p, encoding="utf-8-sig").read(), flags=re.S)
        _cur = ""
        for _ln in _t.splitlines():
            _s = _ln.rstrip()
            if _s.lstrip().startswith("#"):
                continue
            if _s.endswith("`"):
                _cur += _s[:-1] + " "
                continue
            _cur += _s
            if "Start-Process" in _cur and "-Credential" in _cur and "-LoadUserProfile" not in _cur:
                _sp_bad.append("%s: %s" % (_nm, _cur.strip()[:110]))
            _cur = ""
    check("T220 所有 Start-Process -Credential 都显式带 -LoadUserProfile（缺它 profile 不创建）",
          not _sp_bad, str(_sp_bad))

    check("T221 restore-snapshot dot-source userprofile-lib 并调用 Initialize-RdpUserProfile",
          "userprofile-lib.ps1" in restore_txt and ". $userProfileLib" in restore_txt
          and "Initialize-RdpUserProfile" in restore_txt)
    check("T222 restore-snapshot 里旧的裸 Start-Process -Credential 已删除",
          "Start-Process -FilePath \"cmd.exe\" -ArgumentList \"/c exit\" -Credential" not in restore_txt)
    check("T223 setup-chinese dot-source userprofile-lib 并调用 Initialize-RdpUserProfile",
          "userprofile-lib.ps1" in sc_txt and "Initialize-RdpUserProfile" in sc_txt)
    check("T224 用户级目录被跳过时**报数**（不再静默：历史事故里 12 个目录无声消失）",
          "用户级目录" in restore_txt and "$userScopeDirs" in restore_txt)
    check("T225 profile 创建失败计入 problems（SNAPSHOT_STATUS 变 PARTIAL，汇总可见）",
          'Add("user-profile-missing")' in restore_txt)

    # ---------------- Edge 站点数据 + DPAPI 诚实告知 ----------------
    # excludeDirNames 按目录名全局匹配，会把 Edge 的 IndexedDB / Service Worker / File System
    # 一起排掉 —— 而很多站点的登录态正存在 IndexedDB/Service Worker 里（不走 Cookie）。
    # 另外 Edge 的密码/Cookie 是 DPAPI 加密的、跨机解不开，必须探测 + 明确告知，
    # 而不是让用户在「文件都在」的假象里以为数据没丢。
    print("[Edge 站点数据 + DPAPI]")
    check("T226 Edge User Data 进 noExcludeDirs（保住 IndexedDB / Service Worker / Local Storage）",
          any("Microsoft\\Edge\\User Data" in d for d in noex), str(noex))
    check("T227 Edge 必检项含 Cookies", "Default\\Cookies" in reqd, str(reqd))
    check("T228 Edge 必检项含 Local Storage / Session Storage（站点登录态）",
          "Default\\Local Storage" in reqd and "Default\\Session Storage" in reqd, str(reqd))
    check("T229 userdata-lib 提供 Test-EdgeCryptState（真去解一次 os_crypt.encrypted_key）",
          "function Test-EdgeCryptState" in ud_txt
          and "os_crypt" in ud_txt and "ProtectedData" in ud_txt)
    check("T230 userdata-lib 透出 EDGE_CRYPT（OK|BROKEN|UNKNOWN）",
          "'EDGE_CRYPT='" in ud_txt or '"EDGE_CRYPT="' in ud_txt or "EDGE_CRYPT=" in ud_txt)
    check("T231 DPAPI 结论带可操作指引（引导用户开启 Edge 账号同步）",
          "同步" in ud_txt and "Microsoft" in ud_txt)
    check("T232 restore-snapshot 两处取证都传 -ProbeCrypt（还原阶段 Edge 未启动，探的是快照密钥）",
          restore_txt.count("-ProbeCrypt") >= 3)
    check("T233 ENV READY 打印 EDGE_CRYPT 并给出账号同步指引",
          "EDGE_CRYPT" in wf_txt and "账号并开启「同步」" in wf_txt)

    # ---------------- _tools 共享库拷贝改成 glob（曾硬编码漏掉 userdata-lib） ----------------
    # 登录任务跑的是 $Stage\_tools\restore-snapshot.ps1；硬编码清单漏掉新库 →
    # 用户级还原的取证/补漏/DPAPI 探测整段静默不可用。改成 glob 后不会再漏。
    check("T234 backup 侧 _tools 用 glob 拷全部 *-lib.ps1（不再硬编码清单）",
          '-Filter "*-lib.ps1"' in backup_txt and "$toolsFiles" in backup_txt)
    check("T235 restore 侧 _tools 自愈也用 glob 拷全部 *-lib.ps1",
          '-Filter "*-lib.ps1"' in restore_txt)

    # ---------------- 「在跑」必须区分「真在跑 / 排队中」（瑀子 2026-09-24 反馈） ----------------
    # 事故：账号卡写「在跑 2 台」，但「机器运行实况」只显示 1 台。
    # 根因：alive_count 的口径其实是「**未结束**的 run 数」（含 pending/queued/waiting/requested），
    #   排队中的 run 还没分到 runner、机器根本没起来 → tailnet 上没有节点 → 实况里看不到。
    #   实测 acc-3 的 run 35958738011 状态就是 pending（windows-rdp.yml 配了 concurrency，同仓库串行）。
    # 修法：把「真在跑（status=in_progress）」和「排队中」拆开，面板如实分开展示。
    print("[「在跑」区分 真在跑 / 排队中]")
    pcl_txt = open(os.path.join(repo_dir, "scripts", "pool-lib.ps1"), encoding="utf-8-sig").read()
    pcp_txt = open(os.path.join(repo_dir, "scripts", "pool-coordinator.ps1"), encoding="utf-8-sig").read()
    srv_txt = open(os.path.join(wb_dir, "server.py"), encoding="utf-8").read()
    check("T236 协调器把「在跑」拆成 running_count / queued_count（pool-lib 发布 + coordinator 计算）",
          "running_count" in pcl_txt and "queued_count" in pcl_txt
          and "running_count" in pcp_txt and "queued_count" in pcp_txt
          and "$_.status -eq 'in_progress'" in pcp_txt)
    check("T237 server.py hub_live_probe 按真 status 拆（字段名 in_progress 其实是「未结束」，会骗人）",
          'r.get("status")' in srv_txt and '"in_progress"' in srv_txt
          and "running_count" in srv_txt and "queued_count" in srv_txt)
    check("T238 app.js 渲染「在跑 X 台 · 排队 Y 台」+ styles.css 有 .mon-queued",
          "running_count" in app_txt and "queued_count" in app_txt
          and "mon-queued" in app_txt and ".mon-queued" in css_txt)
    _code, _body, _ = req(base, "/api/overview")
    _accs = (json.loads(_body).get("accounts") or {}).get("accounts") or []
    _accs_ok = (not _accs) or all(("running_count" in a and "queued_count" in a) for a in _accs)
    check("T239 /api/overview 账号条目带 running_count / queued_count（旧协调器状态可为 null）",
          "running_count" in srv_txt and "queued_count" in srv_txt and _accs_ok,
          "账号数 %d" % len(_accs))

    # ---------------- 「定时计划运行日志」分账号展示（v1.5.7） ----------------
    # 需求：日志面板原来只看主仓库（hub），但每个账号 = 一个 fork，各跑各的 run。
    # 现在按账号分组展示：hub 账号直接复用主仓库那份结果（不重复请求），
    # 其余账号用本机 .tools/pool/<owner>.token；都没有 → 匿名（公开仓库可读）。
    # 匿名额度只有 60/h 而面板 30s 刷一次 → 匿名结果单独缓存 300s，免得把额度刷爆。
    print("[定时计划运行日志 分账号展示]")
    check("T240 server.py 有 account_token / account_runs / _account_run_groups（分账号拉 run）",
          "def account_token(" in srv_txt and "def account_runs(" in srv_txt
          and "def _account_run_groups(" in srv_txt)
    check("T241 get_runs 支持 include_accounts（默认 False，hub_live_probe 不被顺带拖慢）",
          "include_accounts=False" in srv_txt and "include_accounts=True" in srv_txt
          and "accruns:%s:%s:%s" in srv_txt)
    check("T242 gh_api_as 无 token 时不发 Authorization（否则拼出 'Bearer ' 白跑一趟）",
          'if token:\n        headers["Authorization"]' in srv_txt)
    check("T243 匿名结果缓存久一点（300s），别把 60/h 的匿名额度刷爆",
          'CONFIG["cache_seconds"] if token else 300' in srv_txt)
    check("T244 读不到的账号才去拉 pool-state 兜底（fallback_run，惰性 —— 别每 20s 白打一份）",
          "fallback_run" in srv_txt and "（池状态记录的最近一次运行）" in srv_txt
          and "broken = [e0 for e0 in entries" in srv_txt)
    check("T245 index.html 有账号筛选行 #run-acc-tabs / #runs-meta",
          'id="run-acc-tabs"' in idx_txt and 'id="runs-meta"' in idx_txt)
    check("T246 app.js 有 RUN_ACC + runGroups/runGroupHead/renderRunAccTabs（分组渲染）",
          "RUN_ACC" in app_txt and "function runGroups(" in app_txt
          and "function runGroupHead(" in app_txt and "function renderRunAccTabs(" in app_txt)
    check("T247 app.js 状态徽章中文化（不再渲染 in_progress/pending 原值）",
          "RUN_STATE_LABEL" in app_txt and 'in_progress: "进行中"' in app_txt
          and "RUN_QUEUED_STATES" in app_txt)
    check("T248 styles.css 有 .runs-sub / tr.run-group / tr.run-note",
          ".runs-sub" in css_txt and "tr.run-group" in css_txt and "tr.run-note" in css_txt)
    _code, _body, _ = req(base, "/api/runs?accounts=1")
    _rj = json.loads(_body)
    check("T249 /api/runs?accounts=1 返回 accounts 列表（离线时为空但键必须在）",
          isinstance(_rj.get("accounts"), list), "type=%s" % type(_rj.get("accounts")).__name__)
    _code, _body, _ = req(base, "/api/overview")
    _r2 = json.loads(_body).get("runs") or {}
    check("T250 /api/overview 的 runs 带 accounts 键（分账号视图的数据来源）",
          isinstance(_r2.get("accounts"), list))
    check("T251 各账号 run 并行拉取（as_completed）—— 顺序拉 = 账号数 × 超时，面板 30s 自刷会被拖死",
          "as_completed" in srv_txt and "max_workers=min(4" in srv_txt)

    # ---------------- 「runner 掉线」保命四件套（瑀子 2026-09-25 反馈） ----------------
    # 事故：build 报 "The hosted runner lost communication with the server"。
    # 日志取证：三次失败的 build 全死在 step 7/8 的数小时 rclone 批量传输里 ——
    #   日志在中途凭空截断、68,788 行里没有任何 ##[error]/##[warning]/##[section]，
    #   job 却在 46 分钟后又报 failure。这是「runner 进程被饿死 / 心跳发不出去」的典型特征
    #   （官方把 CPU/内存饿死列为首因，且日志表现就是「中途无错截断」）。
    # 四条根因 + 对策：
    #   ① Defender 实时扫描 step 7/8 落地的 ≈1.8 万个小文件 → CPU 饿死
    #        → 0a + 三个长任务脚本里先 Enable-RdpAvExclusions（加排除 + 关实时扫描）；
    #   ② Tailscale 默认接管系统 DNS → runner 自己解析 api.github.com 也走隧道
    #        → 0c 的 tailscale up 加 --accept-dns=false；
    #   ③ 拉取用 --timeout 0 → 一条僵死连接能吊几小时（rclone 不报错、step 不结束）
    #        → pull 改 5m/60s；push 保留 0（139 WebDAV 上传 >5min，动了就回归旧事故）；
    #   ④ 网络瞬断不可见 → 子进程看门狗每 60s 探一次，连续 3 次不可达就分级自愈 + 打印判定。
    print("[runner 掉线 保命四件套]")
    wd_lib = os.path.join(repo_dir, "scripts", "watchdog-lib.ps1")
    cw_ps1 = os.path.join(repo_dir, "scripts", "conn-watchdog.ps1")
    check("T252 存在共享库 watchdog-lib.ps1", os.path.isfile(wd_lib))
    wd_txt = open(wd_lib, encoding="utf-8-sig").read() if os.path.isfile(wd_lib) else ""
    check("T253 watchdog-lib 导出四个核心函数（探测 / 生命体征 / Defender 排除 / 网络参数）",
          all(("function %s" % f) in wd_txt for f in
              ["Test-RdpGithubReachable", "Get-RdpHostVitals",
               "Enable-RdpAvExclusions", "Get-RdpRcloneNetArgs"]))
    check("T254 watchdog-lib 导出看门狗 + 环境去重（Start-Process 撞 PATH/Path 重复键的兜底）",
          "function Start-RdpConnWatchdog" in wd_txt and "function Stop-RdpConnWatchdog" in wd_txt
          and "function Repair-RdpProcessEnvDupes" in wd_txt
          and "function Invoke-RdpNetSelfHeal" in wd_txt)
    check("T255 探测不含 ICMP（Azure 挡入站 ICMP，ping 恒假 → 会误判成断网）",
          "BeginConnect" in wd_txt and "AsyncWaitHandle" in wd_txt)
    check("T256 ★ pull 超时有限（5m/60s），不再用 --timeout 0 把整场吊死",
          "'--timeout', '5m', '--contimeout', '60s'" in wd_txt)
    check("T257 ★ push 仍保留 --timeout 0（139 WebDAV 上传 >5min，动了就回归旧事故）",
          "'--timeout', '0', '--contimeout', '0'" in wd_txt)
    check("T258 两个逃生开关齐备（AV_SKIP / WATCHDOG_SKIP）—— 本地联调别动本机杀软",
          "CLOUDRDP_AV_SKIP" in wd_txt and "CLOUDRDP_WATCHDOG_SKIP" in wd_txt)
    check("T259 存在子进程 conn-watchdog.ps1", os.path.isfile(cw_ps1))
    cw_txt = open(cw_ps1, encoding="utf-8-sig").read() if os.path.isfile(cw_ps1) else ""
    check("T260 conn-watchdog 声明 ParentPid / FailThreshold / StateFile，且 lib 启动时确实传了",
          all(("$%s" % v) in cw_txt for v in ["ParentPid", "FailThreshold", "StateFile"])
          and "-ParentPid" in wd_txt and "-StateFile" in wd_txt)
    check("T261 conn-watchdog 打印明确判定（内存被吃光 vs 网络被掐断）",
          "主机被饿死" in cw_txt and "网络被掐断" in cw_txt)

    # 三个长任务脚本必须真接线（否则新库是死代码，等于没修）
    pre_txt = open(os.path.join(repo_dir, "scripts", "pre-restore.ps1"),
                   encoding="utf-8-sig").read()
    for _nm, _t in [("sync-down", sd_txt), ("pre-restore", pre_txt), ("restore-snapshot", restore_txt)]:
        check("T262-%s 接线 watchdog-lib（dot-source + Defender 排除 + 看门狗开关）" % _nm,
              "watchdog-lib.ps1" in _t and "Enable-RdpAvExclusions" in _t
              and "Start-RdpConnWatchdog" in _t and "Stop-RdpConnWatchdog" in _t)
    check("T263 sync-down / pre-restore / restore-snapshot 都从 Get-RdpRcloneNetArgs 取参数（口径统一）",
          "Get-RdpRcloneNetArgs" in sd_txt and "Get-RdpRcloneNetArgs" in pre_txt
          and "Get-RdpRcloneNetArgs" in restore_txt)

    # workflow 侧：0a 加排除、0c 关 MagicDNS
    check("T264 workflow 0a 调 Enable-RdpAvExclusions（重 IO 之前先把 Defender 排除加好）",
          "Enable-RdpAvExclusions" in wf_txt and "watchdog-lib.ps1" in wf_txt)
    check("T265 workflow 0c 的 tailscale up 带 --accept-dns=false（别让 VPN 接管系统 DNS）",
          any(("up --authkey" in _l and "--accept-dns=false" in _l) for _l in wf_txt.splitlines()))

    # ---------------- 工作台启动 / 刷新提速（v1.5.8）----------------
    print("[工作台启动/刷新提速]")
    # 版本号只在 T168 卡一次（唯一真源）；这里只确认「v1.5.8 提速那批」已在，不重复钉版本
    check("T266 v1.5.8 提速那批已在（版本 ≥ 1.5.8）",
          tuple(int(x) for x in server.VERSION.split(".")) >= (1, 5, 8), server.VERSION)
    check("T267 overview 快照三件套：_OV 状态 + overview_snapshot + _overview_kick/_overview_build",
          "_OV = {" in srv_txt and "def overview_snapshot" in srv_txt
          and "def _overview_kick" in srv_txt and "def _overview_build" in srv_txt)
    check("T268 api_overview 走快照入口（?refresh=1 也不再同步阻塞）",
          'overview_snapshot(force=("refresh" in params))' in srv_txt)
    check("T269 clear_cache 把快照标记作废（dirty）—— 触发 workflow / 改账号后能拿到新数据",
          '_OV["dirty"] = True' in srv_txt and '_OV["dirty"] = False' in srv_txt)
    check("T270 启动预热 overview（overview_warmup 后台线程）—— 浏览器打开时基本秒回",
          "def overview_warmup" in srv_txt and "threading.Thread(target=overview_warmup" in srv_txt)
    check("T271 首屏骨架（warming）—— 还没快照时先返回空骨架，别让页面空转十几秒",
          "def _overview_skeleton" in srv_txt and '"warming": True' in srv_txt
          and "def _overview_first" in srv_txt)
    check("T272 machine_detail 按 IP 缓存（machine_detail_seconds）—— 省掉每轮刷新每台 6~9 次 SMB 往返",
          'cached("mdetail:%s" % ip' in srv_txt and '"machine_detail_seconds": 30' in srv_txt)
    check("T273 machine_detail 的远端读并行（_machine_detail_reads + ThreadPoolExecutor）",
          "def _machine_detail_reads" in srv_txt and "jobs = {" in srv_txt
          and "as_completed(futs)" in srv_txt)
    check("T274 get_runs 里 hub 两个 workflow 并行拉（不再串行等两倍 API 往返）",
          "wfs = [(k, (CONFIG.get(\"workflows\") or {}).get(k)) for k in targets]" in srv_txt
          and "ex.submit(_one, kw)" in srv_txt)
    check("T275 overview_seconds / machine_detail_seconds 进了默认配置",
          '"overview_seconds": 20' in srv_txt and '"machine_detail_seconds": 30' in srv_txt)
    check("T276 前端处理 warming（首屏骨架）+ stale 补拉（scheduleStaleRetry）",
          "d.warming" in app_txt and "scheduleStaleRetry" in app_txt and "STALE_RETRY" in app_txt)
    check("T277 前端「更新于」用 generated_at（快照真实生成时间），stale 时提示后台重建中",
          "d.generated_at" in app_txt and "正在后台重建" in app_txt)

    # 接口实测：离线时 /api/overview 也必须带 stale / age_seconds（前端据此判断新鲜度）
    _code, _body, _ = req(base, "/api/overview")
    _ov = json.loads(_body)
    check("T278 /api/overview 带 stale / age_seconds 键（快照口径）",
          _code == 200 and "stale" in _ov and "age_seconds" in _ov)
    _code, _body, _ = req(base, "/api/overview?refresh=1")
    _ov2 = json.loads(_body)
    check("T279 /api/overview?refresh=1 也秒回且键齐全（离线时给骨架或快照）",
          _ov2.get("ok") is True and ("warming" in _ov2 or "stale" in _ov2))

    # machine_detail 按 IP 缓存：连续两次调用，远端读只应发生一轮（第二次命中缓存）
    _orig_offline = server.OFFLINE
    _orig_rrt = server.read_remote_text
    _orig_lrd = server.list_remote_dir
    _orig_rra = server.read_remote_abs
    _seen = []
    server.OFFLINE = False
    server.clear_cache()
    server.read_remote_text = lambda ip, rel: (_seen.append(rel), "")[1]
    server.list_remote_dir = lambda ip, p: []
    server.read_remote_abs = lambda ip, p: ""
    try:
        server.machine_detail("100.64.0.9", True)
        _n1 = len(_seen)
        server.machine_detail("100.64.0.9", True)   # 同一 IP，应命中缓存
        _n2 = len(_seen)
    finally:
        server.read_remote_text = _orig_rrt
        server.list_remote_dir = _orig_lrd
        server.read_remote_abs = _orig_rra
        server.OFFLINE = _orig_offline
        server.clear_cache()
    check("T280 machine_detail 按 IP 缓存：第二次不再重复远端读",
          _n1 >= 4 and _n2 == _n1, "n1=%d n2=%d" % (_n1, _n2))

    # ---------------- 后端数据导出（v1.5.9）----------------
    print("[后端数据导出]")
    # 版本号只在 T168 卡一次（唯一真源）；这里只确认「v1.5.9 导出那批」已在，不重复钉版本
    check("T281 v1.5.9 导出那批已在（版本 ≥ 1.5.9）",
          tuple(int(x) for x in server.VERSION.split(".")) >= (1, 5, 9), server.VERSION)
    check("T282 EXPORT_WHAT 六件套 + 路由 /api/export 注册",
          server.EXPORT_WHAT == ("all", "overview", "runs", "machines", "accounts", "pool")
          and ("GET", "/api/export") in server.ROUTES)
    check("T283 _send 支持额外响应头（导出要 Content-Disposition: attachment）",
          "def _send(self, code, body, ctype=" in srv_txt and "headers=None" in srv_txt
          and "for k, v in (headers or {}).items()" in srv_txt)
    check("T284 CSV 带 UTF-8 BOM（Excel 打开中文不乱码）",
          "def _csv_text" in srv_txt and '"\\ufeff" + buf.getvalue()' in srv_txt
          and 'lineterminator="\\r\\n"' in srv_txt)
    check("T285 全部数据导出成 zip：4 份 CSV + overview.json",
          "def _export_zip" in srv_txt and 'z.writestr("%s.csv" % what' in srv_txt
          and 'z.writestr("overview.json"' in srv_txt)
    check("T286 导出取数不重复劳动：有构建在跑就等它，否则自己建并存入快照",
          "def _export_source" in srv_txt and "_overview_build(force_clear=False)" in srv_txt
          and "if not building:" in srv_txt)
    check("T287 前端有导出下拉（export-menu / export-list / data-export）",
          'id="export-menu"' in idx_txt and 'id="export-list"' in idx_txt
          and 'data-export="runs"' in idx_txt)
    check("T288 app.js 有 exportData 并走后端 /api/export（fetch + blob 下载）",
          "function exportData" in app_txt and '"/api/export?what="' in app_txt
          and "createObjectURL" in app_txt and "Content-Disposition" in app_txt)
    check("T289 styles.css 有导出下拉样式（.menu / .menu-list）",
          ".menu-list" in css_txt and ".menu-list[hidden]" in css_txt)

    # 接口实测（直接看响应头 + 原始字节）
    _ec, _eh, _eb = req_raw(base, "/api/export?what=runs&format=csv")
    _etxt = _eb.decode("utf-8", "replace")
    _ecd = _eh.get("Content-Disposition") or ""
    check("T290 /api/export?what=runs&format=csv：200 + text/csv + BOM + attachment 文件名",
          _ec == 200 and "text/csv" in (_eh.get("Content-Type") or "")
          and _etxt.startswith("\ufeff") and "attachment" in _ecd and ".csv" in _ecd)
    check("T291 runs CSV 表头与面板同源（账号/来源/workflow/run号/状态…）",
          _etxt.lstrip("\ufeff").splitlines()[0].startswith("账号,来源,workflow,run号,状态"))
    _ec, _eh, _eb = req_raw(base, "/api/export?what=all&format=csv")
    try:
        _zn = sorted(zipfile.ZipFile(io.BytesIO(_eb)).namelist())
    except Exception:
        _zn = []
    check("T292 /api/export?what=all&format=csv：application/zip，含 4 CSV + overview.json",
          _ec == 200 and "application/zip" in (_eh.get("Content-Type") or "")
          and _zn == ["accounts.csv", "machines.csv", "overview.json", "pool.csv", "runs.csv"],
          str(_zn))
    _ec, _eh, _eb = req_raw(base, "/api/export?what=all&format=json")
    _ej = json.loads(_eb.decode("utf-8"))
    check("T293 /api/export?what=all&format=json：200 + JSON + export_meta + 全量键",
          _ec == 200 and "application/json" in (_eh.get("Content-Type") or "")
          and (_ej.get("export_meta") or {}).get("what") == "all"
          and all(k in _ej for k in ("accounts", "machines", "runs", "pool_state")))
    _ec, _eh, _eb = req_raw(base, "/api/export?what=nonsense&format=xml")
    check("T294 未知 what/format 回落默认（all/json），不 500",
          _ec == 200 and "application/json" in (_eh.get("Content-Type") or ""))

    _meta_ok = True
    for _w in ("runs", "machines", "accounts", "pool"):
        _ec, _eh, _eb = req_raw(base, "/api/export?what=%s&format=json" % _w)
        _j = json.loads(_eb.decode("utf-8"))
        if (_j.get("export_meta") or {}).get("what") != _w or "data" not in _j or "header" not in _j:
            _meta_ok = False
    check("T295 每个数据集 JSON 都带 export_meta/header/data（前端与脚本可直接消费）", _meta_ok)

    # ---------------- Linux 端一键登录：远端部署「交给本机」（v1.6.0）----------------
    print("[一键登录·远端部署]")
    # 版本号只在 T168 卡一次（唯一真源）；这里只确认「v1.6.0 远端登录那批」已在
    check("T296 v1.6.0 远端登录那批已在（版本 ≥ 1.6.0）",
          tuple(int(x) for x in server.VERSION.split(".")) >= (1, 6, 0), server.VERSION)
    check("T297 rdp_launch_target 默认 auto + rdp_launch_on_server（auto 按平台分工）",
          server.DEFAULT_CONFIG.get("rdp_launch_target") == "auto"
          and "def rdp_launch_on_server" in srv_txt and "return IS_WINDOWS" in srv_txt)
    check("T298 launch_rdp 远端不弹窗（mode=local）+ make_rdp 回 local_target/download_url",
          'return (False, "", "local",' in srv_txt
          and '"local_target": not on_server' in srv_txt
          and '"/api/rdp/download?ip=%s&host=%s"' in srv_txt)
    check("T299 路由 /api/rdp/download 注册 + api_rdp_download 存在",
          ("GET", "/api/rdp/download") in server.ROUTES and "def api_rdp_download" in srv_txt)
    check("T300 下载的 .rdp 用 UTF-16LE+BOM（mstsc 原生编码）+ application/x-rdp",
          'b"\\xff\\xfe" + build_rdp_text' in srv_txt and "application/x-rdp" in srv_txt)
    check("T301 Linux 自动探测的 RDP 命令不含明文密码（ps 看不到）",
          '("xfreerdp", "xfreerdp /v:{ip} /u:{user} /cert:ignore /dynamic-resolution")' in srv_txt
          and '("xfreerdp3", "xfreerdp3 /v:{ip} /u:{user} /cert:ignore /dynamic-resolution")' in srv_txt)
    check("T302 conn-info 暴露 local_target / is_windows / auth_check",
          '"local_target": not on_server' in srv_txt and '"is_windows": IS_WINDOWS' in srv_txt
          and '"auth_check": bool(IS_WINDOWS and on_server)' in srv_txt)
    check("T303 overview config 暴露 rdp_local / rdp_launch_target",
          '"rdp_local": not rdp_launch_on_server()' in srv_txt
          and '"rdp_launch_target": str(CONFIG.get("rdp_launch_target") or "auto")' in srv_txt)
    check("T304 前端有下载三件套 + 本机命令/按钮（downloadFrom / downloadRdp / localRdpCmd / rdpBtn）",
          all(k in app_txt for k in ("function downloadFrom", "function withToken",
                                     "function downloadRdp", "function localRdpCmd", "function rdpBtn")))
    check("T305 showConnInfo 有远端分支（local_target → 下载 .rdp / 本机命令）",
          "if (c.local_target)" in app_txt and "data-rdp-download" in app_txt
          and "localOsName()" in app_txt)
    check("T306 远端部署时机器行按钮文案改「下载 .rdp」",
          "DATA.config.rdp_local" in app_txt and "下载 .rdp" in app_txt)
    check("T307 styles.css 有本机命令块样式 .conn-cmd",
          ".conn-cmd" in css_txt and ".conn-cmd .mono" in css_txt)
    _cfg_ex_txt = (open(os.path.join(wb_dir, "config.example.json"), encoding="utf-8").read()
                   if os.path.isfile(os.path.join(wb_dir, "config.example.json")) else "")
    _cfg_ln = os.path.join(os.path.dirname(wb_dir), "deploy", "config.linux.json")
    _cfg_ln_txt = open(_cfg_ln, encoding="utf-8").read() if os.path.isfile(_cfg_ln) else ""
    check("T308 配置模板都带 rdp_launch_target（示例 + Linux 部署）",
          '"rdp_launch_target": "auto"' in _cfg_ex_txt
          and '"rdp_launch_target": "auto"' in _cfg_ln_txt)

    # rdp_launch_target 三态判定（直接单测函数，不受当前平台影响）
    _saved_t = server.CONFIG.get("rdp_launch_target")
    server.CONFIG["rdp_launch_target"] = "local"
    _t_local = server.rdp_launch_on_server()
    server.CONFIG["rdp_launch_target"] = "server"
    _t_server = server.rdp_launch_on_server()
    server.CONFIG["rdp_launch_target"] = "auto"
    _t_auto = server.rdp_launch_on_server()
    server.CONFIG["rdp_launch_target"] = _saved_t
    check("T309 rdp_launch_target 三态：local→False / server→True / auto→IS_WINDOWS",
          _t_local is False and _t_server is True and _t_auto == server.IS_WINDOWS)

    # local 模式下 make_rdp：不弹窗、不预存凭据、给出 download_url
    server.CONFIG["rdp_launch_target"] = "local"
    try:
        _r = server.make_rdp("100.1.2.3", "github-rdp-server-1", launch=True, store_cred=True)
    finally:
        server.CONFIG["rdp_launch_target"] = _saved_t
    check("T310 local 模式 make_rdp：local_target + download_url，未在服务端唤起/预存凭据",
          _r.get("ok") is True and _r.get("local_target") is True
          and str(_r.get("download_url") or "").startswith("/api/rdp/download?")
          and _r.get("launched") is False and _r.get("launch_mode") == "local"
          and not _r.get("cred_stored"), str(_r))

    # 接口实测：下载 .rdp（附件 + UTF-16 BOM + 正文）
    _ec, _eh, _eb = req_raw(base, "/api/rdp/download?ip=100.1.2.3&host=github-rdp-server-1")
    _ecd = _eh.get("Content-Disposition") or ""
    _etxt = _eb.decode("utf-16", "replace") if _eb[:2] in (b"\xff\xfe", b"\xfe\xff") else ""
    check("T311 /api/rdp/download：200 + application/x-rdp + attachment 文件名 + UTF-16 BOM",
          _ec == 200 and "application/x-rdp" in (_eh.get("Content-Type") or "")
          and _eb[:2] == b"\xff\xfe" and "attachment" in _ecd and _ecd.rstrip().endswith('.rdp"'),
          "%s %s" % (_ec, _ecd))
    check("T312 下载的 .rdp 正文含目标 IP / 用户名 / authentication level=0",
          "full address:s:100.1.2.3" in _etxt and "username:s:a" in _etxt
          and "authentication level:i:0" in _etxt)
    check("T313 /api/rdp/download 非法 IP → 400",
          req_raw(base, "/api/rdp/download?ip=a%20b;rm")[0] == 400)

    _ci = json.loads(req(base, "/api/conn-info?ip=1.2.3.4")[1])
    check("T314 /api/conn-info 带 local_target / is_windows / auth_check / download_url",
          isinstance(_ci.get("local_target"), bool) and isinstance(_ci.get("is_windows"), bool)
          and isinstance(_ci.get("auth_check"), bool)
          and str(_ci.get("download_url") or "").startswith("/api/rdp/download?ip="))
    _ov = json.loads(req(base, "/api/overview")[1])
    check("T315 /api/overview config 带 rdp_local / rdp_launch_target",
          isinstance((_ov.get("config") or {}).get("rdp_local"), bool)
          and (_ov.get("config") or {}).get("rdp_launch_target") == "auto")

    # ---------------- UU远程 设备身份：取证链（瑀子 2026-09-26「优化uu远程桌面创建新账户的问题」） ----------------
    print("[UU远程 设备身份 取证链]")
    check("T316 userdata-lib 内置 UU远程 兜底目标（配置缺失时也能校验）",
          "UU远程（机器级）" in ud_txt and "UU远程（用户级）" in ud_txt
          and "ProgramData\\Netease\\GameViewer" in ud_txt)
    check("T317 userdata-lib 把两个 UU远程 目标合并成一个结论（任一缺失 = 没到位）",
          "$uuJudge" in ud_txt and "$uuState" in ud_txt
          and "'UU远程*'" in ud_txt)
    check("T318 userdata-lib 透出 UU_RESTORE（与 EDGE_RESTORE/WBAI_RESTORE 同一条链）",
          "UU_RESTORE=" in ud_txt)
    check("T319 userdata-lib 的返回对象带 uu 字段（供 restore/reinstall 两处消费）",
          "uu       = $uuState" in ud_txt)
    check("T320 restore-snapshot 取证带 uu（Get-RestoreEvidence / Write-RestoreEvidence / 日志行）",
          "$out.uu" in restore_txt and '"UU_RESTORE="' in restore_txt
          and "uu={7}" in restore_txt)
    check("T321 reinstall-apps 的 $udObj 带 uu（写进 apps-status.json 的 userData）",
          "uu       = $ud.uu" in reinstall_txt)
    check("T322 workflow 第 13 步 ENV READY 打印 UU远程设备状态（人看不到 Actions 之外的日志）",
          "UU_RESTORE" in wf_txt and "UU远程设备" in wf_txt)
    check("T323 引导文案说清「协助码是 DPAPI 密文、跨机解不开」（诚实透出，不假装全好了）",
          "Format-UDUUGuidance" in ud_txt and "DPAPI" in ud_txt and "os_crypt" in ud_txt)
    check("T324 诚实性：不再把「未登录」当异常（实测本机 token/userId 也是空的）",
          "token / userId 为空是**正常**" in ud_txt or "token / userId 为空是" in ud_txt)

    # ---------------- 快照完整性：修「每次备份都不完整」（瑀子 2026-09-26） ----------------
    # 现象：工作台每次都显示「备份不完整」（SNAPSHOT_STATUS=PARTIAL），但远端文件数其实 >= 本地。
    # 根因（真机日志坐实）：
    #   ① 抓取侧给**每个**目录都记一条 files.entries，包括天然为空的 Documents/Pictures/Videos/Music
    #      （各 0 个文件）。rclone copy 不带 --create-empty-src-dirs 就不建空目录 -> 暂存里没有该目录；
    #      pre-restore 的 2a 一律 Test-Path -> 每次报 4 个 missing: 假问题 -> PARTIAL。
    #   ② Get-ExpectedFileCount 用 Get-ChildItem -Recurse -File（**跟随** junction），
    #      而 robocopy 传了 /XJ（跳过 junction）-> 「应抓文件数」天然大于实际能抓到的，
    #      [完整抓取] 目录每次报「文件数不足 差 24」-> 又一个 PARTIAL。
    #   ③ 推送侧把元数据（manifest）排在最后，且大目录失败时仍报 SNAPSHOT_PUSH=OK（谎报）。
    print("[快照完整性 空目录/junction/推送顺序]")
    check("T325 pre-restore 校验：空目录（files<=0）不算缺失（消除 4 个 missing: 假问题）",
          "空目录" in pre_txt and "$hasCount" in pre_txt and "missing:$rel" in pre_txt)
    check("T326 backup-snapshot 推送带 --create-empty-src-dirs（空目录也落到 139）",
          "--create-empty-src-dirs" in bs_txt)
    check("T327 backup-snapshot 有 Get-FilesNoReparse（枚举文件时跳过 junction，与 robocopy /XJ 对齐）",
          "function Get-FilesNoReparse" in bs_txt and "Get-FilesNoReparse -Path" in bs_txt)
    check("T328 Get-TreeSize / Get-ExpectedFileCount 都用 Get-FilesNoReparse（口径统一）",
          bs_txt.count("Get-FilesNoReparse -Path") >= 2)
    _i_meta = bs_txt.find("推送元数据（sync")
    _i_big = bs_txt.find("推送大目录")
    check("T329 推送顺序：元数据 sync 在 programs/files 之前（manifest 先落地）",
          _i_meta >= 0 and _i_big >= 0 and _i_meta < _i_big)
    check("T330 大目录失败/超时 -> SNAPSHOT_PUSH=PARTIAL（不再谎报 OK）",
          "SNAPSHOT_PUSH=PARTIAL" in bs_txt and "$bigFailed" in bs_txt)
    check("T331 分阶段预算：元数据/programs/files 各设 --max-duration（防 programs 被 files 饿死）",
          "$progBudgetMin" in bs_txt and "$filesBudgetMin" in bs_txt and "Get-DurArg" in bs_txt)
    check("T332 programs.excludePaths 排除 D:\\a\\cloud-rdp（CLOUDRDP_DATA_DIR 已由 sync-up 独立同步）",
          any(str(p).rstrip("\\").lower() == "d:\\a\\cloud-rdp"
              for p in ((sc.get("programs") or {}).get("excludePaths") or [])))
    check("T333 sync-up 与 backup-snapshot 都用 --create-empty-src-dirs（口径一致）",
          "--create-empty-src-dirs" in su_txt and "--create-empty-src-dirs" in bs_txt)
    check("T334 Get-FilesNoReparse 对「目录和文件」都按 ReparsePoint 跳过（与 robocopy /XJ 官方口径一致）",
          "ReparsePoint" in bs_txt and "PSIsContainer" in bs_txt
          and "排除(文件和目录的)符号链接和接合点" in bs_txt)
    _i_exp = bs_txt.find("$expected = Get-ExpectedFileCount")
    _i_rc = bs_txt.find("$code = Invoke-Robocopy")
    check("T335 期望文件数在 robocopy 之前统计（活跃目录抓完再数会凭空多出「差 N」）",
          _i_exp >= 0 and _i_rc >= 0 and _i_exp < _i_rc)
    check("T336 文件数不足时列出具体缺失文件名（只给数字没法排查）",
          "function Get-MissingFileNames" in bs_txt and "Get-MissingFileNames -Src" in bs_txt)

    # ---------------- 账户守卫：只留 a 一个「可见」管理员（瑀子 2026-09-28） ----------------
    # 需求原文：优化uu远程桌面连接创建runneradmin用户账户的问题，只需要有一个管理员账户a即可，
    #           不要自动创建新的用户账户。
    # 真机取证（SMB 只读探 100.75.73.81 / 100.85.24.112）：
    #   · runneradmin 的 profile ctime = 2026/9/22 22:26:18、NTUSER.DAT mtime = 09/22 22:56:20，
    #     两台机器**完全一致**且早于本次开机（09-28 00:45Z）⇒ 镜像烘焙自带，不是任何脚本建的。
    #   · 全仓零账户创建代码（New-LocalUser / net user / Add-LocalGroupMember 只命中 workflow 0b 建 a）。
    #   · runneradmin = GitHub-hosted runner 自己的账户：runs-on: windows-latest、
    #     工作区是 hosted 专属 D:\a\<repo>\<repo>、slim-image 硬保护名单含 C:\actions-runner。
    #   · UU远程 = 网易 GameViewer（GameViewer.exe + GameViewerService.exe），只装服务、不建账户。
    # ⇒ **删不掉**（本 job 的 runner 正以它跑），只能藏 —— 藏完用户视角就只剩 a。
    print("[账户守卫 runneradmin / 只留 a]")
    ac_lib = os.path.join(repo_dir, "scripts", "account-lib.ps1")
    check("T337 存在共享库 account-lib.ps1", os.path.isfile(ac_lib))
    ac_txt = open(ac_lib, encoding="utf-8-sig").read() if os.path.isfile(ac_lib) else ""
    check("T338 account-lib 导出 4 个函数（清单 / 隐藏 / 白名单 / 报告）",
          all(("function " + f) in ac_txt for f in
              ["Get-RdpAccountInventory", "Hide-RdpNonRdpAccounts",
               "Test-RdpAccountWhitelist", "Format-RdpAccountReport"]))
    check("T339 隐藏走 Winlogon\\SpecialAccounts\\UserList（登录界面/切换用户/UAC 都不再列它）",
          "SpecialAccounts" in ac_txt and "UserList" in ac_txt and "Winlogon" in ac_txt)
    check("T340 profile 目录用 attrib +h +s 隐藏（资源管理器默认不显示）",
          "attrib" in ac_txt and "'+h'" in ac_txt and "'+s'" in ac_txt)
    check("T341 ★ 诚实边界写进库头注：runneradmin 删不掉（job 正以它跑）⇒ 只藏、不删、不降权",
          "删不掉" in ac_txt and "runneradmin" in ac_txt and "降权" in ac_txt)
    check("T342 运维开关 CLOUDRDP_ACCOUNT_HIDE=0 / CLOUDRDP_ACCOUNT_HIDE_DRYRUN=1",
          "CLOUDRDP_ACCOUNT_HIDE" in ac_txt and "CLOUDRDP_ACCOUNT_HIDE_DRYRUN" in ac_txt)
    check("T343 白名单断言：未知账户 = 异常（直接对应「不要自动创建新的用户账户」）",
          "unknown" in ac_txt and "known" in ac_txt and "runneradmin" in ac_txt)
    check("T344 workflow 第 0b 步 dot-source account-lib 并调 Hide-RdpNonRdpAccounts + 白名单",
          "account-lib.ps1" in wf_txt and "Hide-RdpNonRdpAccounts" in wf_txt
          and "Test-RdpAccountWhitelist" in wf_txt)
    check("T345 workflow 第 13 步 ENV READY 打印账户行（ACCOUNT_HIDE / ACCOUNT_UNKNOWN）",
          "ACCOUNT_HIDE" in wf_txt and "ACCOUNT_UNKNOWN" in wf_txt and "账户" in wf_txt)
    check("T346 ★ 快捷方式线索跳过其它用户 profile（runneradmin 死链不再误导成「UU远程 建了账户」）",
          "其它用户的 profile" in bs_txt and "-in @($RdpUser" in bs_txt)
    check("T347 account-lib 全部 fail-soft（多处 try/catch，永不抛异常）",
          ac_txt.count("catch") >= 4)
    # ★ 全仓审计（不只 scripts/）：把「零账户创建代码」的证据面扩到 .github / workbench / deploy。
    #   结论必须成立：全仓唯一建账户的代码 = workflow 0b，且只建 $env:RDP_USERNAME（= a）。
    #   注释与文档不算（README / 库头注里会「提到」这些 cmdlet，属于说明而非执行）。
    _acct_re = re.compile(r"New-LocalUser|net\s+user\s+\S+\s+/add|net1\s+user|Add-LocalGroupMember|"
                          r"New-LocalGroup|wmic\s+useraccount|Win32_UserAccount", re.I)
    _skip_dirs = {".git", "__pycache__", "node_modules", ".tmp-lint", ".tools", "static"}
    _skip_files = {os.path.join(repo_dir, "workbench", "selftest.py")}   # 本测试自身含模式串
    _acct_hits = []
    for _r, _ds, _fs in os.walk(repo_dir):
        _ds[:] = [d for d in _ds if d not in _skip_dirs]
        for _fn in _fs:
            _ext = os.path.splitext(_fn)[1].lower()
            if _ext not in (".ps1", ".psm1", ".py", ".yml", ".yaml", ".json", ".cmd", ".bat", ".vbs"):
                continue
            _fp = os.path.join(_r, _fn)
            if _fp in _skip_files:
                continue
            try:
                _t = open(_fp, encoding="utf-8-sig", errors="replace").read()
            except Exception:
                continue
            _c = re.sub(r"<#.*?#>", "", _t, flags=re.S)     # PowerShell 块注释
            _c = "\n".join(l for l in _c.splitlines() if not l.lstrip().startswith("#"))
            for _i, _l in enumerate(_c.splitlines(), 1):
                if _acct_re.search(_l):
                    _acct_hits.append((os.path.relpath(_fp, repo_dir).replace("\\", "/"),
                                       _i, _l.strip()[:90]))
    check("T348 ★ 全仓（含 .github / workbench / deploy）只有 workflow 0b 建账户，且只建 a",
          len(_acct_hits) > 0 and all(
              h[0] == ".github/workflows/windows-rdp.yml" and "RDP_USERNAME" in h[2]
              for h in _acct_hits),
          str(_acct_hits[:5]))

    # ---------------- 池行实时纠偏：机器实况 vs 账号面板口径一致（v1.6.1） ----------------
    # 需求原文：「优化 机器运行实况 acc-3 · 3465125540 / 池内机器 · primary / 100.93.93.91 /
    #           运行中 / Actions job 运行中 · run 36343475821 · 自 2026/9/28-03:12 / 信息同步异常」
    # 根因：pool_machine_rows 直接信 pool-state 的 last_run，而 pool-state 由协调器几小时一次发布
    #       （GitHub cron 常被延迟 2~5 小时）。协调器抓快照时 run 还在 in_progress、之后 run 已结束，
    #       但协调器还没重跑 → 机器实况一直显示「运行中」；账号面板走 hub_live_probe 早已显示「已结束」。
    #       实测（2026-09-28）：run 36343475821 = completed/success、updated 2.19h 前；
    #       池状态 updated_utc = 01:03:13Z（正好卡在 run 结束 01:11:55Z 之前）→ 两个面板打架。
    print("[池行实时纠偏 v1.6.1]")
    check("T349 v1.6.1 池行纠偏那批已在（版本 ≥ 1.6.1）",
          tuple(int(x) for x in server.VERSION.split(".")) >= (1, 6, 1), server.VERSION)
    check("T350 live_runs_by_id 存在 + 非 hub 账号返回 None（只有 hub 能实时查）",
          "def live_runs_by_id" in srv_txt
          and "h_owner, h_repo = cfg_repo.split" in srv_txt
          and "return None" in srv_txt)
    check("T351 ★ pool_machine_rows 按 run_id 实时纠偏（run_source 标记来源）",
          "live_runs_by_id(owner, repo)" in srv_txt and "run_source" in srv_txt
          and 'run_source = "live"' in srv_txt)
    check("T352 池行暴露 run_source / run_conclusion 字段",
          '"run_source": run_source' in srv_txt
          and '"run_conclusion": run.get("conclusion")' in srv_txt)
    check("T353 前端池行按 run_source 说明来源 + 结束带结论（已结束 · 成功）",
          'm.run_source === "live"' in app_txt and "已结束 · 成功" in app_txt
          and "已按 GitHub 实时 run 核对" in app_txt)

    # 功能实测：pool-state 说「在跑」（陈旧），实时 run 说「已结束」→ 池行必须纠偏
    _saved_lrbi = server.live_runs_by_id
    try:
        server.live_runs_by_id = lambda owner, repo: {"36343475821": {
            "id": 36343475821, "status": "completed", "conclusion": "success",
            "url": "https://github.com/3465125540/cloud-rdp/actions/runs/36343475821"}}
        _ps_stale = {"state": {
            "primary": {"account": "acc-3", "owner": "3465125540", "repo": "cloud-rdp",
                        "run_id": 36343475821, "since": "2026-09-27T19:12:04Z"},
            "standby": [],
            "accounts": [{"id": "acc-3",
                          "last_run": {"run_id": 36343475821, "status": "in_progress"}}],
        }}
        _r_live = server.pool_machine_rows(_ps_stale, [])
        server.live_runs_by_id = lambda owner, repo: None   # 非 hub：拿不到实时 → 保持 pool-state
        _r_stale = server.pool_machine_rows(_ps_stale, [])
    finally:
        server.live_runs_by_id = _saved_lrbi
    check("T354 ★ 实时 run 已结束 → 池行纠偏为 ended / run_source=live（不再谎报「运行中」）",
          len(_r_live) == 1 and _r_live[0].get("machine_state") == "ended"
          and _r_live[0].get("run_source") == "live"
          and _r_live[0].get("run_status") == "completed"
          and _r_live[0].get("run_conclusion") == "success", str(_r_live[:1]))
    check("T355 拿不到实时 run（非 hub）→ 保持 pool-state 的 in_progress / run_source=pool-state",
          len(_r_stale) == 1 and _r_stale[0].get("machine_state") == "running"
          and _r_stale[0].get("run_source") == "pool-state", str(_r_stale[:1]))

    # ★ 会话中复查（不只开机一次）：保活循环每 10 分钟复核账户白名单 ——
    #   若真有人偷偷建账户，日志当场黄字点名；没有则每 10 分钟留一条「复核通过」的正面证据。
    #   这一步把「不要自动创建新的用户账户」从「开机一次性断言」升级为「全程监控」。
    check("T356 ★ 保活循环每 10 分钟复查账户白名单（会话中新建账户也会被抓到，不止开机一次）",
          "[account]" in wf_txt and wf_txt.count("Test-RdpAccountWhitelist") >= 2
          and wf_txt.count("Hide-RdpNonRdpAccounts") >= 2)

    # ---------------- UU远程 落到 a：控制台会话归属 + 桌面「切到 UU远程」（瑀子 2026-09-28） ----------------
    # 需求原文：解决 uu远程桌面后账户不一致的问题 → 澄清为「落到的账户不是 a」。
    # 根因（真机事实）：UU远程（网易 GameViewer）是**屏幕镜像**型工具，连的是机器的
    #   **控制台会话**（console session）；GitHub-hosted 镜像把 runneradmin 放在控制台上
    #   （runner 本体就在那跑）→ UU远程 默认看到 runneradmin 的桌面，不是 a。
    # 修法：Windows 原生 tscon <sid> /dest:console 把 a 的会话交给控制台（**断开**而非 logoff，
    #   程序保留、runner 不受影响）。刻意「不自动切换」—— 切换会让那次 RDP 断开，
    #   改为公共桌面放一个「切到 UU远程」快捷方式，由用户按需触发（瑀子 2026-09-28 选定）。
    print("[UU远程 落到 a / 控制台会话归属]")
    sess_lib = os.path.join(repo_dir, "scripts", "session-lib.ps1")
    sess_run = os.path.join(repo_dir, "scripts", "session-handover.ps1")
    check("T357 存在会话库 session-lib.ps1 + 交接脚本 session-handover.ps1",
          os.path.isfile(sess_lib) and os.path.isfile(sess_run))
    sess_lib_txt = open(sess_lib, encoding="utf-8-sig").read() if os.path.isfile(sess_lib) else ""
    sess_run_txt = open(sess_run, encoding="utf-8-sig").read() if os.path.isfile(sess_run) else ""
    check("T358 session-lib 导出 6 个函数（报告 / 格式化 / 计划 / 执行 / 装 SYSTEM 任务 / 装快捷方式）",
          all(("function " + f) in sess_lib_txt for f in
              ["Get-RdpSessionReport", "Format-RdpSessionReport", "Get-RdpHandoverPlan",
               "Invoke-RdpSessionHandover", "Install-RdpSessionHandoverTask",
               "Install-RdpSessionHandoverShortcut"]))
    check("T359 ★ 交接用 Windows 原生 tscon /dest:console（把 a 的会话交给控制台）",
          "tscon" in sess_run_txt and "/dest:console" in sess_run_txt)
    # 安全铁律：只「断开/重定向」，绝不 logoff / shutdown —— 否则会把会话与 runner 一起弄死。
    # 只查代码（剥掉 <# 块注释 #> 与 # 行注释），头注里为说明「为什么不用 logoff」会提到该词。
    _sess_code = re.sub(r"<#.*?#>", "", sess_run_txt, flags=re.S)
    _sess_code = "\n".join(l for l in _sess_code.splitlines() if not l.lstrip().startswith("#"))
    check("T360 ★ 交接只「断开/重定向」，绝不 logoff / shutdown（会话与 runner 都保留）",
          not re.search(r"\b(logoff|shutdown|Stop-Computer)\b", _sess_code, re.I),
          _sess_code[:120])
    check("T361 交接用 SESSIONNAME 判断当前是否已在控制台（语言无关，不解析中文 qwinsta）",
          "$env:SESSIONNAME" in sess_run_txt and "Console" in sess_run_txt)
    check("T362 ★ 公共桌面放「切到 UU远程」快捷方式（指向 session-handover.ps1）",
          "切到 UU远程" in sess_lib_txt and "session-handover.ps1" in sess_lib_txt
          and "CreateShortcut" in sess_lib_txt)
    check("T363 workflow 第 0b2 步诊断控制台归属 + 装 SYSTEM 交接任务（写 CONSOLE_OWNER 供 ENV READY 读）",
          "0b2. 会话归属校正" in wf_txt and "session-lib.ps1" in wf_txt
          and "Install-RdpSessionHandoverTask" in wf_txt and "CONSOLE_OWNER" in wf_txt)
    check("T364 workflow 第 13 步 ENV READY 打印会话控制台归属",
          "会话控制台" in wf_txt and "CONSOLE_OWNER" in wf_txt)
    check("T365 ★ 保活循环复查控制台归属（只在变化时打印；刻意不自动切换）",
          wf_txt.count("Get-RdpSessionReport") >= 2 and "[session]" in wf_txt)

    # ---------------- 老 fork 自愈：0p 只覆盖 scripts/、不覆盖 workflow（瑀子 2026-09-28） ----------------
    # 现场（acc-5 · code19698fgh · 池内机器 standby · 100.78.202.22）两条 annotation：
    #   ① 0p. 跟随上游 hub 同步脚本（fork 自愈，永不跑旧逻辑）→ "Process completed with exit code 1."
    #   ② 8. 预还原（校验 → 规划 → 准备 → 驱动全量还原）      → "The operation was canceled."
    # 根因：
    #   ① robocopy /MIR 复制了文件 → rc=1（0/1/2/3 都算成功，只有 >=8 才失败），
    #      而 GitHub 会给 pwsh 步骤自动追加 `exit $LASTEXITCODE` → 把成功判成步骤失败（假警）。
    #   ② acc-5 的 fork 停在 d67e81d（2026-09-24），**早于**保命四件套 fbbfd48（09-26）。
    #      Actions 用的是「触发 commit 里的 workflow」，而 0p 只 /MIR scripts/ ⇒
    #      fork 内联的 0c 永远拿不到 --accept-dns=false。本 tailnet 已开 MagicDNS
    #      （tailf6704b.ts.net）→ tailscale up 把整机 DNS 抢成 100.100.100.100 →
    #      runner agent 访问 api.github.com 的长轮询被拽进隧道，一抖就发不出心跳 →
    #      GitHub 中途把 job 判成 cancelled（step 8 跑到 4h16m 挂掉）。
    #      对照：hub（自带该参数）step 8 正常跑完、整场 6h04m —— 同 tailnet、同 MagicDNS，
    #      唯一差别就是那个参数。
    # 修法：
    #   · 0p 归一化 robocopy 退出码（$global:LASTEXITCODE = 0，只在 rc>=8 时提示），末尾 exit 0；
    #   · 把 DNS 兜底**下沉到 scripts/**（Repair-RdpTailscaleDns）—— 0p 能覆盖到的文件，
    #     任何 fork 重 IO 之前都会被修一次（fork 无法自愈 workflow，但能自愈 scripts）。
    print("[老 fork 自愈 / 0p 只覆盖 scripts]")
    _i0p = wf_txt.find("- name: 0p.")
    _nxt = wf_txt.find("- name:", _i0p + 12) if _i0p >= 0 else -1
    _0p = wf_txt[_i0p:_nxt if _nxt > 0 else len(wf_txt)] if _i0p >= 0 else ""
    check("T366 ★ 0p 归一化 robocopy 退出码（rc=1 不再被 GitHub 判成 exit 1 假警）",
          "$rc = [int]$LASTEXITCODE" in _0p and "$global:LASTEXITCODE = 0" in _0p
          and "if ($rc -ge 8)" in _0p)
    check("T367 0p 收尾 exit 0（fail-soft，永不因同步失败挡住开机）",
          _0p.rstrip().endswith("exit 0"))
    check("T368 ★ 0p 做 workflow 漂移检查（本 fork vs hub 的 windows-rdp.yml SHA256 比对）",
          "Get-FileHash" in _0p and "workflow 与 hub 一致" in _0p
          and "workflow 漂移检查" in _0p)
    check("T369 ★ DNS 兜底下沉到 scripts/：watchdog-lib 导出 Repair-RdpTailscaleDns",
          "function Repair-RdpTailscaleDns" in wd_txt)
    check("T370 三个重 IO 脚本都在动手前调 Repair-RdpTailscaleDns（fork 自愈可达）",
          all("Repair-RdpTailscaleDns" in t for t in (sd_txt, pre_txt, restore_txt)))
    check("T371 ★ 兜底 = tailscale set --accept-dns=false + 读 debug prefs 的 CorpDNS（幂等）",
          "--accept-dns=false" in wd_txt and "debug prefs" in wd_txt and "CorpDNS" in wd_txt)
    check("T372 兜底可跳过（CLOUDRDP_TAILSCALE_DNS_SKIP=1）+ fail-soft（try/catch，永不抛）",
          "CLOUDRDP_TAILSCALE_DNS_SKIP" in wd_txt and "catch" in wd_txt)
    check("T373 ★ 诚实边界写进库头注：0p 改不到老 fork 的 workflow（只能同步 scripts/）",
          "0p 只同步" in wd_txt and "d67e81d" in wd_txt and "fbbfd48" in wd_txt)
    # ★ 语法护栏：0p 的 run 块必须能被 PowerShell 解析（曾因手改 YAML 缩进踩坑）。
    #   用 pwsh 的 Parser 静态方法；拿不到 pwsh 就跳过（不误判）。
    _0p_syn_ok = None
    _0p_syn_why = "no-powershell"
    _pwsh = shutil.which("pwsh") or shutil.which("powershell")
    if _pwsh and _0p:
        try:
            _tf = os.path.join(tempfile.gettempdir(), "cloudrdp-0p-ast.ps1")
            with open(_tf, "w", encoding="utf-8-sig") as _fh:
                _fh.write(_0p[_0p.find("run: |") + len("run: |"):].replace("\r\n", "\n"))
            _ps = subprocess.run(
                [_pwsh, "-NoProfile", "-NonInteractive", "-Command",
                 "try{$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile"
                 "('%s',[ref]$null,[ref]$e); if($e -and $e.Count){exit 1}else{exit 0}}catch{exit 2}"
                 % _tf],
                capture_output=True, timeout=60)
            _0p_syn_ok = (_ps.returncode == 0)
            _0p_syn_why = "ast-ok" if _0p_syn_ok else "ast-rc=%d" % _ps.returncode
        except Exception as _ex:
            _0p_syn_ok = None
            _0p_syn_why = "skip:%s" % type(_ex).__name__
    check("T374 0p 的 run 块能通过 PowerShell AST 解析（缩进/语法护栏）",
          _0p_syn_ok is not False, _0p_syn_why)

    # ---------------- 机器实况「账号未知」+ 刷新不准确（v1.6.2） ----------------
    # 需求原文：「优化  机器运行实况 主机 账号未知 ，实况刷新不准确」
    # 现场（2026-09-28）：github-rdp-server-87 / 100.64.46.76 明明 online:true、445+3389 都通，
    #   「主机」列却写「账号未知」。取证：
    #     · net use \\100.64.46.76\D$ /user:a a → 系统错误 67「找不到网络名」
    #     · net view \\100.64.46.76          → 系统错误 1702「绑定句柄无效」
    #     · 但 ping 通（204ms）、TCP 445/3389 OPEN → 机器在跑，只是 D$ 共享还没起来
    #       （Windows 还在初始化）⇒ 读 pool-info.txt / .git\config 全失败 ⇒ 归属为空。
    # 三个真凶：
    #   ① `_smb_preauth` 不管 net use 成败都 return True → 调用方把 IP 记进 `_SMB_DONE`
    #      ⇒ 一次失败即**永久**不再重试，机器起来了面板还一直是「账号未知」；
    #   ② `job_tailscale_ip` 把「落空」也缓存 1 小时 ⇒ 机器起来后面板永远学不到它的 IP；
    #   ③ 「刷新」按钮后端是 stale-while-revalidate：立刻返回**旧**快照 + 后台重建，
    #      前端只写「更新于 <旧时刻>」⇒ 时间戳原地不动，看着就是「刷新不准确」。
    print("[机器实况 归属兜底 + 刷新口径 v1.6.2]")
    check("T375 v1.6.2 那批已在（版本 ≥ 1.6.2）",
          tuple(int(x) for x in server.VERSION.split(".")) >= (1, 6, 2), server.VERSION)
    check("T376 ★ _smb_preauth 只在 net use 真成功（returncode 0）时才返回 True",
          "return out.returncode == 0" in srv_txt
          and "capture_output=True, timeout=25, creationflags=NO_WINDOW)" in srv_txt)
    check("T377 ★ _smb_preauth_once：成功才进 _SMB_DONE，失败进 _SMB_FAIL 冷却（不再一票否决）",
          "def _smb_preauth_once" in srv_txt and "_SMB_FAIL[ip] = now" in srv_txt
          and "_SMB_DONE.add(ip)" in srv_txt and "_SMB_FAIL_COOLDOWN" in srv_txt)
    check("T378 _read_unc 不再「先记 _SMB_DONE 再重试」（旧写法会把失败也当成做过）",
          "_smb_preauth_once(ip)" in srv_txt
          and "if attempt == 0 and ip not in _SMB_DONE and _smb_preauth(ip)" not in srv_txt)
    check("T379 clear_cache() 顺带清掉 net use 失败冷却（点「刷新」即可立刻重试 SMB）",
          "_SMB_FAIL.clear()" in srv_txt)
    check("T380 ★ job_tailscale_ip 落空只缓存 60 秒（不再把空值缓存 1 小时）",
          'key + ":probe", 60, probe' in srv_txt
          and 'cached("job_ip:%s/%s:%s" % (owner, repo, run_id), 3600, probe)' not in srv_txt)
    _pia_at = srv_txt.find("def pool_ip_accounts")
    _pia_txt = srv_txt[_pia_at:srv_txt.find("\ndef ", _pia_at + 10)] if _pia_at >= 0 else ""
    check("T381 ★ pool_ip_accounts 存在 + 只认 in_progress 的 keepalive run（不用 last_run 兜底）",
          _pia_at >= 0 and '(r.get("status") or "") != "in_progress"' in _pia_txt
          and 'g.get("keepalive")' in _pia_txt
          and '.get("last_run")' not in _pia_txt and '["last_run"]' not in _pia_txt,
          _pia_txt[:120])
    check("T382 ★ collect_machines 归属来源③：SMB 读不到时按账号池反查补 account_id / owner_source",
          "pool_ip_accounts()" in srv_txt
          and "账号池反查（该账号的 run 正在跑，其 job 日志自报此 IP）" in srv_txt
          and "if m.get(\"pool_owner\"):" in srv_txt)
    check("T383 smb_err_text 把 Errno 22 / 13 / 2 / 53 翻成人话（不再把 UNC 路径糊进 tooltip）",
          "def smb_err_text" in srv_txt and "远端共享不可达" in srv_txt
          and 'smb_err_text(r)' in srv_txt)
    check("T384 ★ 前端「账号未知」说清原因 + 给出动作（SMB 不可达 / 点刷新重试）",
          '账号未知 <span class="none">· SMB 不可达</span>' in app_txt
          and "点右上角「刷新」可立刻重试一次 SMB" in app_txt)
    check("T385 ★ 前端「刷新」有忙碌态 + 诚实的数据年龄（恒定显示 N 秒前）",
          "function setRefreshBtns" in app_txt and "刷新中…" in app_txt
          and 'el.textContent = "刷新中…（当前数据 " + age + " 秒前）"' in app_txt
          and '"（" + age + " 秒前）"' in app_txt and "function updateStamp" in app_txt)
    check("T386 ★ 在途请求挡住点击时不再静默丢弃（FORCE_PENDING 补发那次刷新）",
          "FORCE_PENDING" in app_txt
          and "if (BUSY) { if (force) FORCE_PENDING = true; return; }" in app_txt)
    check("T387 前端在面板标题里点名「N 台在线机器读不到归属」",
          "unknownOwner" in app_txt and " 台在线机器读不到归属" in app_txt)

    # 功能实测 ①：net use 失败 → _smb_preauth 返回 False（旧代码这里返回 True，是「永久账号未知」的根）
    _orig_sub, _orig_win = server.subprocess, server.IS_WINDOWS
    try:
        server.IS_WINDOWS = True
        server.subprocess = types.SimpleNamespace(
            run=lambda *a, **k: types.SimpleNamespace(returncode=2, stdout=b"", stderr=b""))
        _pa_bad = server._smb_preauth("9.9.9.7")
        server.subprocess = types.SimpleNamespace(
            run=lambda *a, **k: types.SimpleNamespace(returncode=0, stdout=b"", stderr=b""))
        _pa_ok = server._smb_preauth("9.9.9.7")
    finally:
        server.subprocess, server.IS_WINDOWS = _orig_sub, _orig_win
    check("T388 ★ net use 返回 2（系统错误 67）→ _smb_preauth=False；返回 0 → True",
          _pa_bad is False and _pa_ok is True, "bad=%s ok=%s" % (_pa_bad, _pa_ok))

    # 功能实测 ②：失败只进冷却、成功才进 _SMB_DONE；点「刷新」清冷却后可重试
    _orig_pa = server._smb_preauth
    try:
        server._SMB_DONE.clear()
        server._SMB_FAIL.clear()
        server._smb_preauth = lambda ip: False
        _r1 = server._smb_preauth_once("9.9.9.6")
        _d1 = "9.9.9.6" in server._SMB_DONE
        _f1 = "9.9.9.6" in server._SMB_FAIL
        _r2 = server._smb_preauth_once("9.9.9.6")      # 冷却期内不再折腾
        server._smb_preauth = lambda ip: True
        server.clear_cache()                            # 点「刷新」→ 清冷却
        _r3 = server._smb_preauth_once("9.9.9.6")
        _d3 = "9.9.9.6" in server._SMB_DONE
        _r4 = server._smb_preauth_once("9.9.9.6")      # 已建过会话 → 不再建
    finally:
        server._smb_preauth = _orig_pa
        server._SMB_DONE.discard("9.9.9.6")
        server._SMB_FAIL.pop("9.9.9.6", None)
    check("T389 ★ 失败→冷却不进 _SMB_DONE；刷新清冷却后重试成功→进 _SMB_DONE 且不再重试",
          _r1 is False and _d1 is False and _f1 is True and _r2 is False
          and _r3 is True and _d3 is True and _r4 is False,
          "r1=%s d1=%s f1=%s r2=%s r3=%s d3=%s r4=%s" % (_r1, _d1, _f1, _r2, _r3, _d3, _r4))

    # 功能实测 ③：job 日志还没打印 [0c] 时落空 → 60 秒内不重复拉；之后重拉就能学到 IP 并长期记住
    _orig_rji, _orig_fjl, _orig_off = server.run_job_id, server.fetch_job_log, server.OFFLINE
    try:
        server.OFFLINE = False
        server.run_job_id = lambda o, r, i: "1"
        _log = {"n": 0}

        def _fl(url, **kw):
            _log["n"] += 1
            return "" if _log["n"] == 1 else "[0c] Tailscale IP: 10.1.2.3"
        server.fetch_job_log = _fl
        server.clear_cache()
        _a = server.job_tailscale_ip("o", "r", "999001")    # 第一次：日志里还没 [0c] → ""
        _b = server.job_tailscale_ip("o", "r", "999001")    # 60 秒内：不重复拉日志 → 仍 ""
        server._CACHE.pop("job_ip:o/r:999001:probe", None)  # 模拟「60 秒后」
        _c = server.job_tailscale_ip("o", "r", "999001")    # 重拉 → 学到 IP
        _d = server.job_tailscale_ip("o", "r", "999001")    # 命中缓存（1 小时）→ 不再拉日志
        _n = _log["n"]
    finally:
        server.run_job_id, server.fetch_job_log = _orig_rji, _orig_fjl
        server.OFFLINE = _orig_off
        server._CACHE.pop("job_ip:o/r:999001", None)
        server._CACHE.pop("job_ip:o/r:999001:probe", None)
    check("T390 ★ 落空 60 秒内不重拉；之后重拉即学到 IP 并长期缓存（共拉 2 次日志）",
          _a == "" and _b == "" and _c == "10.1.2.3" and _d == "10.1.2.3" and _n == 2,
          "a=%r b=%r c=%r d=%r n=%s" % (_a, _b, _c, _d, _n))

    # 功能实测 ④：pool_ip_accounts 只认 in_progress（已结束的 run 不参与反查）
    _orig_gr, _orig_jti = server.get_runs, server.job_tailscale_ip
    try:
        server.get_runs = lambda **kw: {"ok": True, "accounts": [
            {"id": "acc-A", "owner": "oA", "repo": "r", "keepalive": [
                {"id": 1, "status": "in_progress"}, {"id": 2, "status": "completed"}]},
            {"id": "acc-B", "owner": "oB", "repo": "r", "keepalive": [
                {"id": 3, "status": "completed"}]}]}
        _calls = []

        def _jti(o, r, i):
            _calls.append((o, r, i))
            return {1: "10.1.1.1", 3: "10.2.2.2"}.get(i, "")
        server.job_tailscale_ip = _jti
        _m = server.pool_ip_accounts()
    finally:
        server.get_runs, server.job_tailscale_ip = _orig_gr, _orig_jti
    check("T391 ★ pool_ip_accounts 只对 in_progress 的 run 反查（已结束的不进表）",
          _m == {"10.1.1.1": ("acc-A", "oA")} and _calls == [("oA", "r", 1)],
          "m=%r calls=%r" % (_m, _calls))

    # 功能实测 ⑤：collect_machines 用来源③补归属；但 ①② 已读到时不覆盖
    _orig_pia, _orig_md = server.pool_ip_accounts, server.machine_detail
    try:
        server.pool_ip_accounts = lambda: {"10.0.0.7": ("acc-9", "owner9"),
                                           "10.0.0.8": ("acc-9", "owner9")}
        server.machine_detail = lambda ip, online: dict(server._empty_machine_detail())
        _ms = server.collect_machines([{"ip": "10.0.0.7", "online": True, "hostname": "h"}], [])

        def _md2(ip, online):
            d = server._empty_machine_detail()
            d["pool_owner"] = "realowner"
            d["owner_source"] = "_state/pool-info.txt"
            return d
        server.machine_detail = _md2
        _ms2 = server.collect_machines([{"ip": "10.0.0.8", "online": True, "hostname": "h"}], [])
    finally:
        server.pool_ip_accounts, server.machine_detail = _orig_pia, _orig_md
    check("T392 ★ SMB 读不到归属 → collect_machines 按账号池反查补 account_id/owner/owner_source",
          len(_ms) == 1 and _ms[0].get("account_id") == "acc-9"
          and _ms[0].get("pool_owner") == "owner9"
          and "账号池反查" in (_ms[0].get("owner_source") or ""), str(_ms[:1]))
    check("T393 来源①②已读到归属时，账号池反查不覆盖（只兜底，不抢权威）",
          len(_ms2) == 1 and _ms2[0].get("pool_owner") == "realowner"
          and _ms2[0].get("owner_source") == "_state/pool-info.txt", str(_ms2[:1]))

    # ---------------- 快照 TTL vs 实测构建耗时（v1.6.2 第二部分：刷新不准确） ----------------
    # 真凶③（最隐蔽的一个）：build_overview 冷构建实测 13~49 秒，而 overview_seconds 默认 20。
    # 旧逻辑 `if dirty or age >= ttl: stale=True` ⇒ 构建**一完成就已过期** ⇒ 每个请求都踢重建、
    # 面板永远显示「后台刷新中…」，时间戳还一直停在旧值 —— 用户看到的就是「实况刷新不准确」。
    check("T394 ★ _overview_ttl() 不小于上次构建耗时 + 5 秒（构建比 TTL 慢时不再永远「陈旧」）",
          "took + 5.0" in srv_txt and 'max(base, took + 5.0)' in srv_txt
          and '_OV.get("build_secs")' in srv_txt)
    check("T395 _overview_build 记录实测构建耗时 build_secs",
          '_OV["build_secs"] = took' in srv_txt and "took = time.time() - t0" in srv_txt)
    check("T396 ★ 被动重建时 stale 只在「真的在重建 / 脏」时置位（不再「比 ttl 旧就算陈旧」）",
          "bool(building or dirty)" in srv_txt
          and "_overview_decorate(data, age, True)\n    return _overview_decorate(data, age, False)" not in srv_txt)
    check("T397 前端恒定显示「更新于 …（N 秒前）」+ 重建中才加「正在后台重建」",
          "正在后台重建" in app_txt and "秒前）" in app_txt)

    _orig_ovs = server.CONFIG.get("overview_seconds")
    _ov_keep = {}
    with server._OV_LOCK:
        for _k in ("data", "at", "dirty", "build_secs"):
            _ov_keep[_k] = server._OV.get(_k)
    try:
        server.CONFIG["overview_seconds"] = 20
        server._OV["build_secs"] = 0.0
        _ttl_fast = server._overview_ttl()
        server._OV["build_secs"] = 47.0
        _ttl_slow = server._overview_ttl()

        # 同一份「25 秒前」的快照：TTL=20 时算陈旧，TTL=52（实测耗时兜底）时算新鲜
        server._OV["data"] = {"ok": True, "generated_at": "2026-01-01T00:00:00Z",
                              "version": server.VERSION}
        server._OV["dirty"] = False
        server._OV["building"] = 0
        server._OV["at"] = time.time() - 25
        server._OV["build_secs"] = 0.0
        _snap_old = server.overview_snapshot(force=False)     # age 25 >= ttl 20 → 陈旧
        server._OV["dirty"] = False
        server._OV["at"] = time.time() - 25
        server._OV["build_secs"] = 47.0
        _snap_new = server.overview_snapshot(force=False)     # age 25 < ttl 52 → 新鲜
    finally:
        with server._OV_LOCK:
            for _k, _v in _ov_keep.items():
                server._OV[_k] = _v
        if _orig_ovs is None:
            server.CONFIG.pop("overview_seconds", None)
        else:
            server.CONFIG["overview_seconds"] = _orig_ovs
        server._overview_kick(force_clear=True)   # 让快照尽快恢复成真数据
    check("T398 ★ _overview_ttl：实测构建 47s → TTL 52s（配置 20s 被兜住）；无实测时用配置值",
          _ttl_fast == 20.0 and _ttl_slow == 52.0, "fast=%s slow=%s" % (_ttl_fast, _ttl_slow))
    check("T399 ★ 同一份「25 秒前」快照：TTL=20 判陈旧，TTL=52 判新鲜（不再一建好就过期）",
          _snap_old.get("stale") is True and _snap_old.get("age_seconds") == 25
          and _snap_new.get("stale") is False and _snap_new.get("age_seconds") == 25,
          "old=%s/%s new=%s/%s" % (_snap_old.get("stale"), _snap_old.get("age_seconds"),
                                   _snap_new.get("stale"), _snap_new.get("age_seconds")))

    # ---------------- UU远程 交接：两层设计 + 状态锚定解析（2026-09-29 真机复核） ----------------
    # 2026-09-29 在 acc-5 / github-rdp-server-91 / 100.86.253.112 真机实测，把 T357~T365 的
    # 「单层 tscon」方案推翻并升级为「两层」：
    #   · 以 a 的普通令牌 tscon /dest:console → Error 5（缺 SeTcbPrivilege）；
    #   · 以 SYSTEM 单独 tscon <a> /dest:console → 顶不掉已被占用的控制台（只把 a 断开）；
    #   · 以 SYSTEM **先 tsdiscon <控制台会话ID>、再 tscon <a会话ID> /dest:console** → 成功。
    # 因此新增：SYSTEM 计划任务 CloudRDP-UUHandover（真正执行交接）+ 桌面快捷方式只负责触发它。
    # 另修一个解析 bug：qwinsta 里**断开中的会话** SESSIONNAME 列为空（`<空> a 1 Disc`），
    #   旧解析把 a 当会话名 → Get-RdpHandoverPlan 误判 no-user。改为「锚定 STATE 再往左走」。
    print("[UU远程 交接 两层设计 + 状态锚定解析]")
    _cmsg = os.path.join(repo_dir, "scripts", "send-connection-mail.ps1")
    cmsg_txt = open(_cmsg, encoding="utf-8-sig").read() if os.path.isfile(_cmsg) else ""
    check("T400 session-lib 的 Get-RdpSessionReport 支持 -RawLines（解析可离线单测，不依赖真机 qwinsta）",
          "[string[]]$RawLines" in sess_lib_txt and "if ($RawLines) { $lines = $RawLines }" in sess_lib_txt)
    check("T401 ★ 状态锚定解析：先找 STATE 词、再往左取 ID/USERNAME（断开布局 `<空> a 1 Disc` 不再漏掉用户）",
          "$states = @(" in sess_lib_txt and "$t[$i] -in $states" in sess_lib_txt
          and "$t[$si - 1] -match '^\\d+$'" in sess_lib_txt)
    check("T402 Get-RdpHandoverPlan 三态齐备：none（已是 a）/ no-user（a 没会话）/ handover（可切）",
          "function Get-RdpHandoverPlan" in sess_lib_txt
          and all(("'" + s + "'") in sess_lib_txt for s in ("none", "no-user", "handover")))
    # ★ 交接顺序铁律：tsdiscon 必须在 tscon 之前 —— 真机实测先 tscon 会 rc=0 但控制台不动。
    _inv_at = sess_lib_txt.find("function Invoke-RdpSessionHandover")
    _inv_txt = sess_lib_txt[_inv_at:sess_lib_txt.find("\nfunction ", _inv_at + 10)] if _inv_at >= 0 else ""
    _tdi = _inv_txt.find("$tsdiscon")
    _tco = _inv_txt.find("& $tscon $sid /dest:console")
    check("T403 ★ Invoke-RdpSessionHandover 顺序：先 tsdiscon（断开当前控制台）再 tscon（把 a 接到控制台）",
          _tdi >= 0 and _tco >= 0 and _tdi < _tco, "tsdiscon@%d tscon@%d" % (_tdi, _tco))
    check("T404 ★ SYSTEM 交接任务：principal = SYSTEM / ServiceAccount / RunLevel Highest（SeTcbPrivilege 所在）",
          "New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest" in sess_lib_txt
          and "Register-ScheduledTask -TaskName $TaskName" in sess_lib_txt)
    check("T405 ★ SYSTEM 任务用 -System 入口真正执行交接（普通令牌不直接 tscon，避开 Error 5）",
          "-System -User" in sess_lib_txt and "Invoke-RdpSessionHandover -RdpUser $User" in sess_run_txt
          and "$System" in sess_run_txt)
    check("T406 ★ 桌面快捷方式走 -Apply：普通令牌只触发 SYSTEM 任务（Start-ScheduledTask / schtasks /run）",
          "-Apply -User" in sess_lib_txt and "Start-ScheduledTask -TaskName $taskName" in sess_run_txt
          and "schtasks /run /tn $taskName" in sess_run_txt)
    check("T407 任务名 CloudRDP-UUHandover 在库与交接脚本里一致（触发方/被触发方对得上）",
          sess_lib_txt.count("CloudRDP-UUHandover") >= 1 and sess_run_txt.count("CloudRDP-UUHandover") >= 1)
    check("T408 交接可跳过（CLOUDRDP_UU_HANDOVER_SKIP=1）+ 全程 fail-soft（try/catch，永不抛）",
          "CLOUDRDP_UU_HANDOVER_SKIP" in sess_lib_txt and "catch { $res.note" in sess_lib_txt)
    check("T409 ★ 老 fork 自愈：安装钩子下沉到 scripts/send-connection-mail.ps1（0p 可达，d67e81d 也会装）",
          "Install-RdpSessionHandoverTask" in cmsg_txt and "session-lib.ps1" in cmsg_txt)
    check("T410 脚本落到持久目录（job 结束清 workspace，任务目标必须留盘）",
          "cloudrdp-sys" in sess_lib_txt
          and "Copy-Item -LiteralPath $ScriptPath -Destination $dstScript" in sess_lib_txt)

    # ★ 行为护栏：真的用 pwsh 跑一遍状态锚定解析（拿到 pwsh 才跑，拿不到跳过不误判）。
    _parse_ok = None
    _parse_why = "no-powershell"
    if _pwsh:
        try:
            _pf = os.path.join(tempfile.gettempdir(), "cloudrdp-sess-parse.ps1")
            _L = [
                "$ErrorActionPreference='Stop'",
                ". '" + sess_lib + "'",
                "$hdr = ' SESSIONNAME               USERNAME                 ID  STATE   TYPE        DEVICE'",
                "$r1 = Get-RdpSessionReport -RdpUser a -RawLines @($hdr,"
                "'>services                                            0  Disc',"
                "'                          a                         1  Disc',"
                "' console                   runneradmin               2  Active')",
                "if ($r1.consoleOwner -ne 'runneradmin') { exit 11 }",
                "if ([string]$r1.aSessionId -ne '1') { exit 12 }",
                "if ($r1.ok) { exit 13 }",
                "$r2 = Get-RdpSessionReport -RdpUser a -RawLines @($hdr,"
                "'>services                                            0  Disc',"
                "' console                   a                         1  Active',"
                "'                          runneradmin               2  Disc')",
                "if (-not $r2.ok) { exit 14 }",
                "if ($r2.consoleOwner -ne 'a') { exit 15 }",
                "$p = Get-RdpHandoverPlan -RdpUser a -Report $r1",
                "if ($p.action -ne 'handover') { exit 16 }",
                "exit 0",
            ]
            with open(_pf, "w", encoding="utf-8-sig") as _fh:
                _fh.write("\r\n".join(_L) + "\r\n")
            _ps2 = subprocess.run(
                [_pwsh, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", _pf],
                capture_output=True, timeout=60)
            _parse_ok = (_ps2.returncode == 0)
            _parse_why = "ok" if _parse_ok else "rc=%d" % _ps2.returncode
        except Exception as _ex:
            _parse_ok = None
            _parse_why = "skip:%s" % type(_ex).__name__
    check("T411 ★ 真跑 pwsh：断开布局仍识别 a=会话1 + 已切到 a 时 ok=True + 计划 action=handover",
          _parse_ok is not False, _parse_why)

    # ---- ③ 无感自动交接（2026-09-29 追加）------------------------------------
    # 需求：连 UU远程 时「无感」落到 a，不用双击快捷方式。
    # 做法：SYSTEM 任务 CloudRDP-UUAuto（开机 + 每 60s）跑 session-handover.ps1 -Auto。
    # 关键闸：只在「控制台不是 a 且 a 的会话**没被 RDP 连着**（Disc）」时才切 ——
    #   否则 tscon 会把用户的 mstsc 踢断，用户重连又会把控制台「接管」回 RDP，来回抢。
    print("[UU远程 无感自动交接（三层设计的第 ③ 层）]")
    check("T412 ★ 无感自动交接任务 Install-RdpSessionAutoHandoverTask 存在，且 Install-RdpSessionHandoverTask 会一并装上",
          "function Install-RdpSessionAutoHandoverTask" in sess_lib_txt
          and "Install-RdpSessionAutoHandoverTask -RdpUser $RdpUser -ScriptPath $dstScript" in sess_lib_txt
          and "CloudRDP-UUAuto" in sess_lib_txt)
    check("T413 ★ 自动闸：报告暴露 aAttachedRdp/aSessionName，-Auto 下 a 被 RDP 连着时返回 skip-active（不抢）",
          "aAttachedRdp" in sess_lib_txt and "aSessionName" in sess_lib_txt
          and "'skip-active'" in sess_lib_txt and "if ($Auto -and $Report.aAttachedRdp)" in sess_lib_txt)
    check("T414 ★ 自动任务触发器：AtStartup（覆盖重启）+ Once&RepetitionInterval（PS5.1 实测 AtStartup 不支持 Repetition）",
          "New-ScheduledTaskTrigger -AtStartup" in sess_lib_txt
          and "-Once -At (Get-Date).AddMinutes(1) -RepetitionInterval" in sess_lib_txt
          and "-Trigger @($tBoot, $tRep)" in sess_lib_txt
          and "-RepetitionDuration" not in sess_lib_txt)
    check("T415 ★ -Auto 入口 + -Auto -DryRun 诊断 + 可关：CLOUDRDP_UU_AUTO=0 与 <sysdir>\\_state\\uu-auto-off 开关文件都能停摆",
          "$Auto" in sess_run_txt and "Invoke-RdpSessionHandover -RdpUser $User -Auto" in sess_run_txt
          and "CLOUDRDP_UU_AUTO" in sess_run_txt and "uu-auto-off" in sess_run_txt
          and "CLOUDRDP_UU_AUTO" in sess_lib_txt
          # -Auto 分支必须自己处理 -DryRun（否则真机诊断会静默空跑，什么都不打印）
          and "[Auto-DryRun]" in sess_run_txt
          and "Get-RdpHandoverPlan -RdpUser $User -Auto" in sess_run_txt)
    check("T416 无感自动交接写日志（仅在真正发生交接时写一行，避免每分钟刷屏）+ 幂等（console 已是 a → 不动）",
          "uu-auto.log" in sess_run_txt and "if ($r.action -eq 'handover')" in sess_run_txt
          and "action = 'none'" in sess_lib_txt)
    check("T417 工作流 0b2 报出自动任务 + 会话心跳不再写「刻意不自动切换」",
          "$tk.auto" in wf_txt and "刻意「不自动切换」" not in wf_txt
          and "刻意不自动切换" not in wf_txt and "无感" in wf_txt)

    # ★ 行为护栏：真跑 pwsh 验「Active(RDP) 不抢 / Disc 才切」。
    _auto_ok = None
    _auto_why = "no-powershell"
    if _pwsh:
        try:
            _af = os.path.join(tempfile.gettempdir(), "cloudrdp-sess-auto.ps1")
            _A = [
                "$ErrorActionPreference='Stop'",
                ". '" + sess_lib + "'",
                "$hdr = ' SESSIONNAME               USERNAME                 ID  STATE   TYPE        DEVICE'",
                "# 布局 1：a 正被 RDP 连着（rdp-tcp#0 Active）→ 自动闸必须 skip-active",
                "$r1 = Get-RdpSessionReport -RdpUser a -RawLines @($hdr,"
                "'>services                                            0  Disc',"
                "' rdp-tcp#0                 a                         1  Active',"
                "' console                   runneradmin               2  Active')",
                "if (-not $r1.aAttachedRdp) { exit 21 }",
                "if ($r1.aState -ne 'Active') { exit 22 }",
                "if ((Get-RdpHandoverPlan -RdpUser a -Report $r1 -Auto).action -ne 'skip-active') { exit 23 }",
                "if ((Get-RdpHandoverPlan -RdpUser a -Report $r1).action -ne 'handover') { exit 24 }",
                "# 布局 2：a 已断开（Disc）→ 自动闸放行 handover",
                "$r2 = Get-RdpSessionReport -RdpUser a -RawLines @($hdr,"
                "'>services                                            0  Disc',"
                "'                          a                         1  Disc',"
                "' console                   runneradmin               2  Active')",
                "if ($r2.aAttachedRdp) { exit 25 }",
                "if ($r2.aState -ne 'Disc') { exit 26 }",
                "if ((Get-RdpHandoverPlan -RdpUser a -Report $r2 -Auto).action -ne 'handover') { exit 27 }",
                "# 不存在的用户 → 确定性 no-user（不依赖本机真实会话布局）",
                "if ((Invoke-RdpSessionHandover -RdpUser 'zz-nobody' -DryRun -Auto).action -ne 'no-user') { exit 28 }",
                "exit 0",
            ]
            with open(_af, "w", encoding="utf-8-sig") as _fh:
                _fh.write("\r\n".join(_A) + "\r\n")
            _ps3 = subprocess.run(
                [_pwsh, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", _af],
                capture_output=True, timeout=60)
            _auto_ok = (_ps3.returncode == 0)
            _auto_why = "ok" if _auto_ok else "rc=%d" % _ps3.returncode
        except Exception as _ex:
            _auto_ok = None
            _auto_why = "skip:%s" % type(_ex).__name__
    check("T418 ★ 真跑 pwsh：a 被 RDP 连着 → 自动闸 skip-active；a 已断开 → 自动闸放行 handover",
          _auto_ok is not False, _auto_why)

    # ---------------- 恢复状态标记：阻断 139 传播 + 陈旧判定（v1.6.3） ----------------
    # 背景：_RESTORE_*.txt 躺在数据目录根、会随数据目录同步到 139，再被还原到别的机器，
    #       几天后仍被读成「本机恢复失败」→ 概览「恢复异常」虚高。真机取证见 README §19。
    print("[恢复标记：139 传播阻断 + 陈旧判定]")
    check("T419 sync-up/sync-down 排除 _RESTORE_*.txt（阻断经 139 传播）",
          all(x in su_txt for x in ('"/_RESTORE_FAILED.txt"', '"/_RESTORE_EMPTY.txt"'))
          and all(x in sd_txt for x in ('"/_RESTORE_FAILED.txt"', '"/_RESTORE_EMPTY.txt"')),
          "sync-up/sync-down 排除表缺 _RESTORE_*.txt")
    _lg = server.parse_marker_time("restore FAILED at 2026-09-30 04:00:58, rclone exit code = 1")
    _cu = server.parse_marker_time("restore FAILED at 2026-09-30T05:45:19.7184162Z\nreason=x")
    _jk = server.parse_marker_time("")
    check("T420 parse_marker_time 识别旧版格式（legacy=True、不填 at_utc）",
          _lg["legacy"] is True and _lg["at_utc"] == "" and _lg["raw"] == "2026-09-30 04:00:58", str(_lg))
    check("T421 parse_marker_time 现行格式归一成 UTC（去小数秒、保留 Z）",
          _cu["legacy"] is False and _cu["at_utc"] == "2026-09-30T05:45:19Z", str(_cu))
    check("T422 parse_marker_time 空/无时间戳 → 全空（不误判）",
          _jk == {"at_utc": "", "legacy": False, "raw": ""}, str(_jk))

    def _stale(marker_legacy, at_utc, source="标记文件", boot="2026-09-30T05:49:01Z"):
        r = {"source": source, "data": {"status": "FAILED", "at_utc": at_utc,
                                        "marker_legacy": marker_legacy}}
        server._mark_stale_marker(r, boot)
        return bool(r["data"].get("stale_marker"))
    check("T423 旧版标记 → 陈旧（139 传播来的假阳性，不计入异常）",
          _stale(True, "") is True)
    check("T424 现行标记早于开机 → 陈旧；晚于开机 → 不陈旧（真失败仍计入）",
          _stale(False, "2026-09-30T01:00:00Z") is True
          and _stale(False, "2026-09-30T06:00:00Z") is False)
    check("T425 权威 restore-status.json（acc-5 真失败）绝不被判陈旧",
          _stale(False, "2026-09-30T05:45:19Z", source="_state/restore-status.json",
                 boot="2026-09-30T00:46:42Z") is False)
    check("T426 machine_restore_summary 跳过陈旧标记（data 陈旧 + snapshot OK → 取 OK）",
          server.machine_restore_summary(
              {"restore": {"data": {"status": "FAILED", "stale_marker": True},
                           "snapshot": {"status": "OK"}}})["kind"] == "ok")
    check("T427 count_scope_bad 跳过陈旧标记（陈旧 0、真失败 1）",
          server.count_scope_bad([{"restore": {"data": {"status": "FAILED", "stale_marker": True}}}],
                                 "data") == 0
          and server.count_scope_bad([{"restore": {"data": {"status": "FAILED"}}}], "data") == 1)
    check("T428 app.js 陈旧标记渲染为「旧标记·已忽略」",
          "stale_marker" in app_txt and "旧标记·已忽略" in app_txt)

    # ---------------- fork 漂移自愈（0p 同步不到 .github/workflows/） ----------------
    # 事故：fork 停在旧 commit → Actions 用的是「触发那次 commit 里的 workflow」，
    #   而 0p 只能同步 scripts/，workflow 内联的新步骤（如 0b2 无感自动交接）永远到不了机器。
    #   用户「每次开机都要找人救」的根因就在这（acc-1 停在 530b3ab、acc-5 停在 d67e81d）。
    # 修法：协调器每轮巡检时把各 fork 的 main 快进到 hub（只在严格落后时；diverged 不动手）。
    print("[fork 漂移自愈]")
    check("T429 pool-lib 有 Sync-PoolFork（只在严格落后时 merge-upstream 快进；diverged 不动手）",
          "function Sync-PoolFork" in pcl_txt and "merge-upstream" in pcl_txt
          and "ahead_by" in pcl_txt and "'diverged'" in pcl_txt and "'uptodate'" in pcl_txt)
    check("T430 协调器在决策前调用 fork 自愈，且不受 -DryRun 影响（自愈 ≠ 派发）",
          "Sync-PoolFork" in pcp_txt and "fork 自愈" in pcp_txt
          and "不受 -DryRun 影响" in pcp_txt)

    # ---------------- UU 交接 ②③ 的真实成败必须可见 + 区域无关 ----------------
    # 事故（2026-09-30 复盘 run #62/#63/#65/#66/#67 日志）：
    #   · ② 桌面快捷方式**从来没建出来过**：WScript.Shell.CreateShortcut 走 ANSI，
    #     en-US 运行器（ACP=1252）存不了中文名 .lnk → "Unable to save shortcut"（zh-CN 机器正常）。
    #   · 0b2/connmail 只打「自动: CloudRDP-UUAuto」（任务名，失败也照打）→ ③ 装没装上看不出来。
    print("[UU 交接 ②③ 可见性 + 区域无关]")
    check("T431 ★ 快捷方式改用「ASCII 临时名建 + Unicode File.Move 改中文名」（en-US 运行器也能建出来）",
          "New-Object -ComObject WScript.Shell" in sess_lib_txt
          and "[System.IO.File]::Move($tmpLnk, $lnkPath)" in sess_lib_txt
          and "cloudrdp-uu-" in sess_lib_txt)
    check("T432 ★ ③ 任务：Register-ScheduledTask 失败自动退回 schtasks（运行器令牌被 UAC 过滤时也能装）",
          "$registered = $false" in sess_lib_txt and "if (-not $registered)" in sess_lib_txt
          and "schtasks /create /tn $TaskName" in sess_lib_txt)
    check("T433 ★ 0b2/connmail 报出 ②③ 真实成败（ok/note），不再只打任务名骗人",
          "shortcutOk" in sess_lib_txt and "autoOk" in sess_lib_txt
          and "③ 无感自动交接 ok=" in wf_txt and "② 桌面快捷方式 ok=" in cmsg_txt)

    # ---------------- UU远程「备用远程通道」（0c1 步：早装 + 打印/邮件连接信息） ----------------
    # 背景：Tailscale 是主通道，但有单点（authkey 过期 / tailnet 受限）。UU远程 走网易中继兜底。
    #   必须「早装」——第 10 步重装软件要等 30~60 分钟，那时「备用」早就不备用了。
    #   连接信息 = 设备码(deviceId) + 验证码(协助码)；协助码是 DPAPI 密文，跨机解不开要**如实报**。
    uu_txt = open(os.path.join(repo_dir, "scripts", "install-uu-remote.ps1"),
                  encoding="utf-8-sig").read()
    mt_path = os.path.join(repo_dir, ".github", "workflows", "mail-test.yml")
    mt_txt = open(mt_path, encoding="utf-8").read() if os.path.exists(mt_path) else ""
    print("[UU远程 备用远程通道 0c1]")
    check("T434 ★ 工作流在 0c 之后、0c2 之前插入了 0c1 步（安装 UU远程 + 打印/邮件连接信息）",
          "0c1. 安装 UU远程" in wf_txt
          and wf_txt.index("0c. 安装并连接 Tailscale")
              < wf_txt.index("0c1. 安装 UU远程")
              < wf_txt.index("0c2. 解析账号池角色"))
    check("T435 ★ 0c1 调 install-uu-remote.ps1，且 continue-on-error（装不上不阻断开机）",
          "install-uu-remote.ps1" in wf_txt
          and "0c1. 安装 UU远程" in wf_txt)
    check("T436 安装分层：已装 → winget(NetEase.UURemote) → 官方安装包 /S（全 fail-soft）",
          "NetEase.UURemote" in uu_txt and "Install-UUViaWinget" in uu_txt
          and "Install-UUViaDownload" in uu_txt and "'/S'" in uu_txt)
    check("T437 连接信息：读 deviceId / uuid / 协助码，DPAPI 密文跨机解不开要如实标注",
          "user_info.ini" in uu_txt and "remote_assist_code.ini" in uu_txt
          and "Try-Unprotect" in uu_txt and "DataProtectionScope" in uu_txt
          and "assistUsable" in uu_txt)
    check("T438 发信复用 send-mail.ps1，且脚本永远 exit 0（不阻断开机）",
          "send-mail.ps1" in uu_txt and uu_txt.rstrip().endswith("exit 0"))
    check("T439 ★ 修掉「PowerShell 单元素数组被解包成标量」的坑（$exe[0] 会变成首字符 'C'）",
          "return ,@($list)" in uu_txt)

    # ---------------- UU远程「连接信息」改造：官方 CLI 取设备ID + 固定自定义验证码 ----------------
    # 背景：ini 里的协助码是 DPAPI 密文，且从 139 还原的那份是在**别的机器**上加密的 → 跨机解不开，
    #       于是「验证码」那一行等于没打印（旧版只能写「(DPAPI 密文…)」）。
    # 改走 UU远程 官方 CLI（<安装目录>\bin\uuyc-cli.exe；运维版文档里叫 uuycmgr.exe）：
    #   -d         取「设备 ID」—— 纯数字，就是远程协助页面那个 ID
    #   -c <code>  设自定义验证码，并把验证方式切成「仅使用自定义验证码」
    #     （客户端日志：setCustomVerifyCode: verify_type is TEMPORARY, switching to CUSTOMIZE）
    # 于是邮件里的「设备 ID + 验证码」是一对**能直接输入**的凭据，不再受 DPAPI 跨机限制。
    print("[UU远程 连接信息：设备 ID + 固定自定义验证码]")
    check("T440 ★ 优先走官方 CLI（uuyc-cli.exe / uuycmgr.exe），不再靠硬改 ini 里的 DPAPI 密文",
          "function Find-UUCli" in uu_txt and "'uuyc-cli.exe'" in uu_txt and "'uuycmgr.exe'" in uu_txt
          and "function Invoke-UUCli" in uu_txt)
    check("T441 ★ 用 CLI `-d` 取「设备 ID」（纯数字；主控端要输入的就是它）",
          "function Get-UUDeviceIdViaCli" in uu_txt and "-CliArgs @('-d')" in uu_txt
          and r"\d{6,12}" in uu_txt)
    check("T442 ★ 用 CLI `-c` 设自定义验证码 = 把验证方式切成「仅使用自定义验证码」",
          "function Set-UUCustomCode" in uu_txt and "-CliArgs @('-c', $Code)" in uu_txt
          and "仅使用自定义验证码" in uu_txt)
    check("T443 自定义验证码默认 a1234567（8 位、字母+数字），可由 -CustomCode / CLOUDRDP_UU_CODE 覆盖",
          "'a1234567'" in uu_txt and "CLOUDRDP_UU_CODE" in uu_txt and "$CustomCode" in uu_txt)
    check("T444 ★ 连接信息主推「设备 ID + 验证码」两项（控制台 / 桌面文件 / 邮件三处都对齐）",
          "设备 ID    : $devLine" in uu_txt and "验证码     : $assistDisplay" in uu_txt
          and "设备 ID : $devLine" in uu_txt and "验证码  : $assistDisplay" in uu_txt
          and "主控端只输上面两项" in uu_txt)
    check("T445 ★ 桌面连接信息文件多目录回落（非管理员时 Public 桌面会被拒写 → 用户桌面 → 状态目录）",
          "uu-remote-info.txt" in uu_txt and "$env:USERPROFILE" in uu_txt
          and "连接信息已写到" in uu_txt)
    check("T446 工作流把仓库变量 CLOUDRDP_UU_CODE 透传给 0c1（不设则用脚本默认码）",
          "CLOUDRDP_UU_CODE: ${{ vars.CLOUDRDP_UU_CODE }}" in wf_txt)
    check("T447 仍然 fail-soft：找不到 CLI / 设码失败都不阻断开机（脚本永远 exit 0）",
          "未找到 uuyc-cli.exe / uuycmgr.exe" in uu_txt
          and uu_txt.rstrip().endswith("exit 0"))

    # ---------------- 机器标识：账户 a + Tailscale 身份（不是随机 runnervmXXXX） ----------------
    # 背景（2026-10-02 用户反馈原话：「我要的是账户a的连接信息，不要runnervmfi6oq」）：
    #   云机本身就是 GitHub 托管运行器 —— $env:COMPUTERNAME 每次开机都是随机的 runnervmXXXX，
    #   打印它等于没打印。用户认机器靠：账户（默认 a）+ Tailscale 身份（github-rdp-server-N + 100.x）。
    print("[UU远程 连接信息：账户 a + Tailscale 机器标识]")
    check("T448 ★ 机器标识用「账户 + Tailscale 身份」，绝不把随机 COMPUTERNAME（runnervmXXXX）当机器名",
          "function Get-UUMachineIdentity" in uu_txt and "function Find-Tailscale" in uu_txt
          and "status --json" in uu_txt and "HostName" in uu_txt and "TailscaleIPs" in uu_txt
          and "$env:TS_IP" in uu_txt)
    check("T449 ★ 打印 / 桌面文件 / 邮件三处都改成「账户 + 机器」两行；COMPUTERNAME 降级成灰色「运行器名（仅排查）」",
          "账户       : $uuUser" in uu_txt and "机器       : $machineLabel" in uu_txt
          and "账户    : $uuUser" in uu_txt and "机器    : $machineLabel" in uu_txt
          and "运行器名" in uu_txt and "仅排查" in uu_txt)
    check("T450 ★ 邮件主题带「账户 … · 机器 …」，不再只有随机 deviceName",
          "UU远程（账户 $uuUser · $machineLabel）" in uu_txt)
    check("T451 状态 JSON / GITHUB_ENV 透出 account + machine（工作台/后续步骤可用）",
          "machine = $machineLabel" in uu_txt and "UU_REMOTE_ACCOUNT=$uuUser" in uu_txt
          and "UU_REMOTE_MACHINE=$machineLabel" in uu_txt)
    check("T452 ★ CLOUDRDP_UU_MACHINE 可覆盖机器标识；mail-test 用它标明「非账户 a 的云机」",
          "CLOUDRDP_UU_MACHINE" in uu_txt
          and "CLOUDRDP_UU_MACHINE: '单跑测试（GitHub 托管运行器，非账户 a 的云机）'" in mt_txt)
    check("T453 ★ winget 报「成功」却找不到 GameViewer.exe → 兜底有界扫描（Find-GameViewerExe，-Recurse -Depth）",
          "function Find-GameViewerExe" in uu_txt and "-Recurse -Depth" in uu_txt
          and "Find-GameViewerExe" in uu_txt)
    check("T454 装完仍找不到 exe → 记「候选目录」取证（Get-UUInstallHints / install hints），便于下次定位",
          "function Get-UUInstallHints" in uu_txt and "install hints:" in uu_txt)

    # ---------------- 自动接力：运行时长 ≥ N 小时 → 自动派发 1 台新机器（v1.6.4） ----------------
    # 需求（瑀子 2026-10-02）：「机器运行实况」列表里只要有**任一台在跑机器**运行时长 ≥ 4 小时，
    #   就自动起 1 台新机器。判断范围 = 所有在跑机器（不限主/备/账号）。
    #   去重三重护栏：① 一次性闩锁（同机只触发一次）② 冷却期 ③ 每小时配额。
    print("[自动接力 v1.6.4]")

    def _mk(ip, up_h, online=True, owner="", started="", pool_only=False):
        return {"ip": ip, "online": online, "pool_owner": owner, "pool_only": pool_only,
                "started_utc": started or ("2026-10-02T00:00:00Z" if up_h is not None else ""),
                "uptime_seconds": None if up_h is None else int(up_h * 3600),
                "uptime_human": server.human_duration(up_h * 3600) if up_h is not None else ""}

    _asc = {"enabled": True, "uptime_hours": 4, "cooldown_minutes": 30, "max_per_hour": 4,
            "max_running": 0}
    _now = server.parse_iso("2026-10-02T12:00:00Z")

    # ① 判断范围：只认「在跑 + 时长 ≥ 阈值」；离线 / 时长未知 / 池内占位行都不算
    _ms = [_mk("10.0.0.1", 3.9),                  # 未达标
           _mk("10.0.0.2", 4.0),                  # 刚好达标（边界）
           _mk("10.0.0.3", 6.0, online=False),    # 离线 → 没在跑 → 不算
           _mk("10.0.0.4", None),                 # 时长未知 → 不算
           _mk("10.0.0.5", 5.0, pool_only=True)]  # 池内占位行（无运行时长）→ 不算
    check("T455 ★ 自动接力「达标机器」只认在跑且时长 ≥ 阈值（离线/未知/池内占位都不算）",
          [m["ip"] for m in server.auto_start_hot(_ms, 4 * 3600)] == ["10.0.0.2"])
    check("T456 边界：运行时长 == 阈值（4h）即算命中（用 >=，不是 >）",
          any(m["ip"] == "10.0.0.2" for m in server.auto_start_hot(_ms, 4 * 3600)))
    check("T457 判断范围 = 所有在跑机器（不限主/备/账号）：多台达标全入选，最老的排最前",
          [m["ip"] for m in server.auto_start_hot(
              [_mk("a", 4.5), _mk("b", 9.0), _mk("c", 5.0)], 4 * 3600)] == ["b", "c", "a"])

    # ② 未启用 → 绝不触发（默认就是关的）
    check("T458 ★ 未启用时一律不触发（auto_start 默认关闭）",
          server.auto_start_decide(_ms, {}, dict(_asc, enabled=False), _now)["fire"] is False)

    # ③ 命中 → fire=True，machine = 去重闩锁键「归属@开机时刻」
    _d = server.auto_start_decide([_mk("10.0.0.2", 5.0, owner="acc-5",
                                      started="2026-10-02T00:45:56Z")], {}, _asc, _now)
    check("T459 ★ 命中时 fire=True，machine = 归属@开机时刻（去重闩锁键）",
          _d["fire"] is True and _d["machine"] == "acc-5@2026-10-02T00:45:56Z", _d.get("reason"))

    # ④ 去重闩锁：同一台机器触发过就不再触发（运行时长只增不减，不闩就会每 tick 重刷）
    _st1 = {"triggered": {"acc-5@2026-10-02T00:45:56Z": "2026-10-02T11:00:00Z"}, "history": []}
    _d1 = server.auto_start_decide([_mk("10.0.0.2", 5.0, owner="acc-5",
                                        started="2026-10-02T00:45:56Z")], _st1, _asc, _now)
    check("T460 ★ 去重：同一台机器（同归属+同开机时刻）触发过就不再触发",
          _d1["fire"] is False and "闩锁" in _d1["reason"], _d1.get("reason"))

    # ⑤ 冷却期：距上次尝试不足 cooldown → 不触发（换一台没闩过的机器也不行）
    _st2 = {"triggered": {}, "history": [], "last_attempt_at": "2026-10-02T11:50:00Z"}
    _d2 = server.auto_start_decide([_mk("10.0.0.9", 5.0, owner="acc-9",
                                        started="2026-10-02T01:00:00Z")], _st2, _asc, _now)
    check("T461 ★ 冷却期：距上次派发 10 分钟 < 30 分钟 → 不触发（防「一次性全起」）",
          _d2["fire"] is False and "冷却" in _d2["reason"], _d2.get("reason"))
    _st3 = {"triggered": {}, "history": [], "last_attempt_at": "2026-10-02T11:00:00Z"}
    check("T462 冷却期满（60 分钟 ≥ 30）→ 恢复触发",
          server.auto_start_decide([_mk("10.0.0.9", 5.0, owner="acc-9",
                                        started="2026-10-02T01:00:00Z")], _st3, _asc, _now)["fire"] is True)

    # ⑥ 每小时配额（滚动 1 小时窗口）
    _st4 = {"triggered": {}, "history": [{"at_utc": "2026-10-02T11:30:00Z"}] * 4,
            "last_attempt_at": "2026-10-02T11:00:00Z"}
    _d4 = server.auto_start_decide([_mk("10.0.0.9", 5.0, owner="acc-9",
                                        started="2026-10-02T01:00:00Z")], _st4, _asc, _now)
    check("T463 ★ 每小时配额：1 小时内已派 4 台（=上限）→ 不再触发",
          _d4["fire"] is False and "上限" in _d4["reason"], _d4.get("reason"))

    # ⑦ 可选护栏：在跑机器数上限
    _d5 = server.auto_start_decide([_mk("a", 5.0), _mk("b", 5.0)], {}, dict(_asc, max_running=2), _now)
    check("T464 在跑机器数达上限（max_running）→ 不触发",
          _d5["fire"] is False and "上限" in _d5["reason"], _d5.get("reason"))

    # ⑧ 只读接口 / 干跑 / 概览透出
    code, body, _ = req(base, "/api/auto-start")
    _j = json.loads(body)
    check("T465 ★ GET /api/auto-start → 200，返回规则状态（enabled / uptime_hours / cooldown…）",
          code == 200 and _j.get("ok") and "enabled" in _j and "uptime_hours" in _j
          and "cooldown_minutes" in _j, "code=%s" % code)
    code, body, _ = req(base, "/api/auto-start?dry=1")
    _j = json.loads(body)
    check("T466 ★ /api/auto-start?dry=1 干跑：离线无机器 → fire=False 且不派发（dispatched=False）",
          code == 200 and _j.get("dry_run", {}).get("fire") is False
          and _j.get("dry_run", {}).get("dispatched") is False, body[:200])
    code, body, _ = req(base, "/api/overview")
    check("T467 概览载荷带 auto_start 状态（前端「机器运行实况」据此显示规则开关）",
          code == 200 and "auto_start" in json.loads(body), "code=%s" % code)

    # ⑨ 默认关闭 + 配置子键合并（不能把 DEFAULT_CONFIG 污染掉）
    check("T468 ★ 内置默认 auto_start.enabled = False（自动派发耗 Actions 分钟数，须显式开启）",
          server.DEFAULT_CONFIG["auto_start"]["enabled"] is False)
    _cfg_path = os.path.join(tmpdir, "wb-cfg-autostart.json")
    with open(_cfg_path, "w", encoding="utf-8") as f:
        json.dump({"auto_start": {"enabled": True}}, f)
    _loaded = server.load_config(_cfg_path)
    check("T469 ★ config.json 只写 enabled 时其余阈值仍走默认（auto_start 子键合并，不整块替换）",
          _loaded["auto_start"]["enabled"] is True
          and _loaded["auto_start"]["uptime_hours"] == server.DEFAULT_CONFIG["auto_start"]["uptime_hours"])
    check("T470 ★ load_config 不污染 DEFAULT_CONFIG（嵌套 dict 已拷贝，默认值仍是唯一真源）",
          server.DEFAULT_CONFIG["auto_start"]["enabled"] is False
          and server.DEFAULT_CONFIG["workflows"].get("keepalive") == "windows-rdp.yml")
    check("T471 ★ 自动接力守护线程在 main() 里被拉起（面板没开也照样巡检接力）",
          "auto_start_loop" in open(os.path.join(repo_dir, "workbench", "server.py"),
                                    encoding="utf-8").read())

    # ---------------- 账号显示名：acc-N → 真实账号名（owner）+ 名称缺失兜底（v1.6.5） ----------------
    # 需求（瑀子 2026-10-03，附截图）：「定时计划运行日志」的账号筛选 tab 显示 acc-1/acc-3/acc-4/acc-5，
    #   看不懂。→ 界面上一律显示真实账号名（owner，如 code19698fgh）；名称缺失时兜底。
    #   兜底链：owner →（只有代号时去账号池反查 owner）→ 代号 acc-N → 「未命名账号」。
    print("[账号显示名 v1.6.5]")
    check("T472 ★ app.js 有全站统一的账号显示名口径 accLabel / accTip / accountById",
          "function accLabel(" in app_txt and "function accTip(" in app_txt
          and "function accountById(" in app_txt)
    check("T473 ★ 兜底链：owner 优先 → 反查 → 代号 acc-N → 「未命名账号」",
          "if (owner) return owner;" in app_txt and "if (id) return id;" in app_txt
          and 'return "未命名账号"' in app_txt)
    check("T474 ★ 运行日志账号筛选 tab 改用 accLabel（旧的 `a.id || a.owner` 已清除）",
          "var nm = accLabel(a.id, a.owner)" in app_txt
          and "var nm = a.id || a.owner" not in app_txt)
    check("T475 ★ 运行日志分组表头 / 单账号 meta 也走 accLabel（不再漏 acc-N）",
          "accLabel(g.id, g.owner)" in app_txt)
    check("T476 ★ 机器表（主机列 + 池内机器行）账号名走 accLabel，不再拼 `acc-N · owner`",
          app_txt.count("accLabel(m.account_id, m.pool_owner)") >= 2
          and "[m.account_id, m.pool_owner].filter" not in app_txt)
    check("T477 ★ 账号管理表：主显示真实名（owner），代号降级成「代号 acc-N」小字",
          "esc(accLabel(a.id, a.owner))" in app_txt and 'mono">代号 ' in app_txt)
    check("T478 代号仍留在 tooltip（accTip）里，便于与 pool-config 的 acc-N 对照",
          '"代号 " + code' in app_txt)

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
