#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GitHub 虚拟机管理工作台 —— 本地 Web 仪表盘（Python 标准库，零依赖）。

四大面板
--------
  1) GitHub 账号管理   —— 账号池账号清单、Secret 是否就位、各账号当前在跑机
  2) 机器运行实况       —— Tailscale 在线状态 + 池角色（主/备）+ 快照新鲜度
  3) 定时计划运行日志   —— windows-rdp.yml / pool-coordinator.yml 的 Actions run
  4) 一键登录机器       —— 生成 .rdp（cmdkey 预存凭据）并唤起 mstsc

设计原则
--------
  * 只用 Python 标准库，复制即跑，不 npm install。
  * 三条外部链路（GitHub API / Tailscale / SMB）彼此独立，
    任何一条挂了都只影响对应面板，其余照常渲染（降级可见，不白屏）。
  * 所有写操作（启停账号、派发 workflow、落 .rdp）都是「显式动作」，
    不会在轮询里偷偷改状态。

启动
----
    python workbench/server.py                 # 默认 http://127.0.0.1:8787
    python workbench/server.py --port 9000     # 换端口
    python workbench/server.py --no-open       # 不自动开浏览器
    python workbench/server.py --offline       # 离线模式（自测用，不联网）
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"
# 进程启动时刻：用来一眼分辨「浏览器连的是不是重启前的旧实例」——
# 旧实例没有新加的路由，会回 404 "no such api"。页脚/健康接口显示它即可确认。
STARTED_AT = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
STATIC_DIR = os.path.join(HERE, "static")
IS_WINDOWS = os.name == "nt"
NO_WINDOW = 0x08000000 if IS_WINDOWS else 0  # CREATE_NO_WINDOW

# 离线模式：自测用。让所有外部链路返回空壳，验证接口与渲染不炸。
OFFLINE = False
QUIET = False


# ==================================================================== 配置
DEFAULT_CONFIG = {
    # ---- 服务 ----
    "host": "127.0.0.1",
    "port": 8787,
    "open_browser": True,
    "auto_refresh_seconds": 30,

    # ---- 目标仓库 ----
    "repo": "3465125540/cloud-rdp",     # 池 hub（协调器所在仓库）owner/repo
    "ref": "main",

    # ---- 凭据 ----
    # 留空 = 自动发现：env GH_TOKEN/GITHUB_TOKEN → gh auth token → .tools/gh_token.txt
    "token_file": "",

    # ---- 网络 ----
    # auto = 探测 127.0.0.1:7890，通则把代理纳入候选；否则纯直连（也尊重系统 HTTP(S)_PROXY）
    "proxy": "auto",
    "proxy_probe": "127.0.0.1:7890",
    # 这些主机默认「先走代理」；其余默认「先直连」（一般更快）。
    # 实测本机 api.github.com 与 raw.githubusercontent.com 直连都通，
    # 所以默认为空 = 全部直连优先；哪条路失败会自动回退到另一条并记住结果。
    # 若你所在网络直连 raw.githubusercontent.com 不通，把它加进来即可。
    "proxy_hosts": [],
    "first_try_timeout": 15,
    "http_timeout": 30,

    # ---- 账号池 ----
    "pool_config": "scripts/pool-config.json",   # 相对仓库根
    "state_branch": "pool-state",
    "state_path": "state/pool-state.json",

    # ---- workflow 文件名 ----
    "workflows": {
        "keepalive": "windows-rdp.yml",
        "coordinator": "pool-coordinator.yml",
    },
    "run_limit": 25,
    "cache_seconds": 20,

    # ---- 机器实况 ----
    "tailscale_exe": r"C:\Program Files\Tailscale\tailscale.exe",
    "machine_prefix": "github-rdp-server",   # 只把以此开头的 Tailscale 节点当「我们的机器」
    "smb_share": "D$",
    "smb_base": r"D:\cloudrdp-sys",          # 远端系统目录（含 _state / _snapshot）
    "snapshot_stale_minutes": 90,            # 快照超过这么久没更新 → 标记为「陈旧」

    # ---- 一键登录 ----
    "rdp_user": "a",
    "rdp_password": "a",
    "rdp_dir": "",                           # 留空 = 桌面
    "rdp_width": 1920,
    "rdp_height": 1080,
    "rdp_launch": True,                      # 生成后是否自动唤起 mstsc
    "rdp_store_cred": True,                  # 是否 cmdkey 预存凭据（实现免手输密码）
}

CONFIG = dict(DEFAULT_CONFIG)
TOKEN_CACHE = {"value": None, "checked": False}


def _expand(p):
    return os.path.expandvars(os.path.expanduser(str(p))) if p else p


def load_config(path=None):
    """默认值 ← config.json ← 环境变量（后者覆盖前者）。"""
    cfg = dict(DEFAULT_CONFIG)
    path = path or os.environ.get("WORKBENCH_CONFIG") or os.path.join(HERE, "config.json")
    if path and os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                user = json.load(f)
            if isinstance(user, dict):
                for k, v in user.items():
                    if k == "workflows" and isinstance(v, dict):
                        cfg["workflows"].update(v)
                    else:
                        cfg[k] = v
        except Exception as e:  # 配置坏了也不能让服务起不来
            sys.stderr.write("[warn] 读配置失败 %s: %s\n" % (path, e))
    # 环境变量覆盖（只覆盖标量）
    for key in ("host", "repo", "ref", "token_file", "proxy", "tailscale_exe"):
        env = "WORKBENCH_" + key.upper()
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    if os.environ.get("WORKBENCH_PORT"):
        try:
            cfg["port"] = int(os.environ["WORKBENCH_PORT"])
        except ValueError:
            pass
    cfg["port"] = int(cfg["port"])
    return cfg


def pool_config_path():
    p = _expand(CONFIG.get("pool_config") or "")
    if not os.path.isabs(p):
        p = os.path.join(REPO_ROOT, p)
    return p


# ==================================================================== 缓存
_CACHE = {}
_CACHE_LOCK = threading.Lock()


def cached(key, ttl, fn):
    now = time.time()
    with _CACHE_LOCK:
        hit = _CACHE.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    val = fn()
    with _CACHE_LOCK:
        _CACHE[key] = (time.time(), val)
    return val


def clear_cache():
    with _CACHE_LOCK:
        _CACHE.clear()


# ==================================================================== Token
def resolve_token(force=False):
    """按优先级找 GitHub Token。找不到返回 None（多数只读接口匿名也能用一部分）。"""
    if TOKEN_CACHE["checked"] and not force:
        return TOKEN_CACHE["value"]
    token = None

    # 1) 显式配置的 token 文件
    tf = _expand(CONFIG.get("token_file") or "")
    if tf and os.path.isfile(tf):
        try:
            token = open(tf, "r", encoding="utf-8-sig").read().strip()
        except Exception:
            token = None

    # 2) 环境变量
    if not token:
        for env in ("GH_TOKEN", "GITHUB_TOKEN"):
            if os.environ.get(env):
                token = os.environ[env].strip()
                break

    # 3) gh CLI
    if not token:
        gh = shutil.which("gh") or shutil.which("gh.exe")
        if not gh:
            for cand in (os.path.join(REPO_ROOT, "..", ".tools", "bin", "gh.exe"),
                         os.path.join(REPO_ROOT, ".tools", "bin", "gh.exe")):
                if os.path.isfile(cand):
                    gh = os.path.abspath(cand)
                    break
        if gh:
            try:
                out = subprocess.run([gh, "auth", "token"], capture_output=True,
                                     timeout=15, creationflags=NO_WINDOW)
                if out.returncode == 0:
                    t = out.stdout.decode("utf-8", "replace").strip()
                    if t:
                        token = t
            except Exception:
                pass

    # 4) 常见落盘位置
    if not token:
        for cand in (os.path.join(REPO_ROOT, "..", ".tools", "gh_token.txt"),
                     os.path.join(REPO_ROOT, ".tools", "gh_token.txt"),
                     os.path.join(os.path.expanduser("~"), ".workbuddy", "gh_token.txt")):
            if os.path.isfile(cand):
                try:
                    t = open(cand, "r", encoding="utf-8-sig").read().strip()
                    if t:
                        token = t
                        break
                except Exception:
                    pass

    TOKEN_CACHE["value"] = token
    TOKEN_CACHE["checked"] = True
    return token


# ==================================================================== HTTP
def _proxy_url():
    mode = str(CONFIG.get("proxy") or "auto").lower()
    if mode in ("", "none", "off", "false"):
        return ""
    if mode != "auto":
        return mode

    def probe():
        p = CONFIG.get("proxy_probe") or "127.0.0.1:7890"
        try:
            host, _, port = p.partition(":")
            with socket.create_connection((host, int(port)), timeout=0.6):
                return "http://" + p
        except Exception:
            return ""
    return cached("proxy_url", 60, probe)


# 每个主机记住「哪条路走得通」，避免每次都白试一次。
_HOST_ROUTE = {}
_ROUTE_LOCK = threading.Lock()


def _route_order(host):
    """返回该主机要依次尝试的路线，如 ['direct', 'proxy']。"""
    pu = _proxy_url()
    with _ROUTE_LOCK:
        pref = _HOST_ROUTE.get(host)
    if pref == "proxy" and pu:
        return ["proxy", "direct"]
    if pref == "direct":
        return ["direct", "proxy"] if pu else ["direct"]
    hosts = [str(h).lower().lstrip(".") for h in (CONFIG.get("proxy_hosts") or [])]
    first = "proxy" if any(host == h or host.endswith("." + h) for h in hosts) else "direct"
    order = [first, "proxy" if first == "direct" else "direct"]
    return [r for r in order if r == "direct" or pu]


def _remember_route(host, route):
    with _ROUTE_LOCK:
        _HOST_ROUTE[host] = route


def _open_once(url, method, hdrs, data, timeout, route):
    if route == "proxy":
        pu = _proxy_url()
        op = urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": pu, "https": pu}))
    else:
        # 显式禁用环境代理 —— 「直连」就是直连
        op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    with op.open(req, timeout=timeout) as resp:
        return resp.read()


def http_json(url, method="GET", headers=None, body=None, timeout=None, raw=False):
    """发一个 JSON 请求。直连/代理自动择路 + 失败回退。全都失败才抛异常。"""
    timeout = timeout or CONFIG.get("http_timeout", 25)
    hdrs = {"User-Agent": "cloud-rdp-workbench/%s" % VERSION,
            "Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        hdrs["Content-Type"] = "application/json"

    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    routes = _route_order(host)
    first_timeout = min(timeout, int(CONFIG.get("first_try_timeout") or 12))
    last_err = None
    for i, route in enumerate(routes):
        t = first_timeout if (i == 0 and len(routes) > 1) else timeout
        try:
            payload = _open_once(url, method, hdrs, data, t, route)
        except Exception as e:
            last_err = e
            continue
        _remember_route(host, route)
        if raw:
            return payload
        txt = payload.decode("utf-8", "replace")
        return json.loads(txt) if txt.strip() else {}
    raise last_err if last_err else RuntimeError("request failed: %s" % url)


def gh_api(path, method="GET", params=None, body=None, timeout=None):
    """调 GitHub REST API。path 形如 /repos/{owner}/{repo}/actions/runs。"""
    if OFFLINE:
        return {}
    url = "https://api.github.com" + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    headers = {"Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}
    token = resolve_token()
    if token:
        headers["Authorization"] = "Bearer " + token
    return http_json(url, method=method, headers=headers, body=body, timeout=timeout)


def gh_ready():
    """探测 GitHub 链路是否可用（带缓存）。返回 (ok, detail)。"""
    def probe():
        if OFFLINE:
            return {"ok": False, "detail": "离线模式"}
        try:
            gh_api("/rate_limit", timeout=12)
            return {"ok": True, "detail": "GitHub API 可达"}
        except urllib.error.HTTPError as e:
            return {"ok": False, "detail": "GitHub API %s" % e.code}
        except Exception as e:
            return {"ok": False, "detail": "%s: %s" % (type(e).__name__, e)}
    return cached("gh_ready", max(30, CONFIG["cache_seconds"]), probe)


# ==================================================================== 时间工具
def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


_ISO_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$")


def parse_iso(s):
    """尽量宽容地解析 ISO 时间。

    注意：PowerShell 的 `(Get-Date).ToUniversalTime().ToString('o')` 会给出 7 位
    小数秒（如 2026-09-22T03:31:03.7302008Z），而 Python 3.10- 的
    datetime.fromisoformat 只认 3 位或 6 位小数 —— 直接解析会失败，导致池状态
    的「更新时间」显示不出来。这里在小数位超标时截到 6 位再试。
    """
    if not s:
        return None
    txt = str(s).strip()
    if not txt:
        return None
    try:
        return datetime.fromisoformat(txt.replace("Z", "+00:00"))
    except Exception:
        pass
    m = _ISO_RE.match(txt)
    if not m:
        return None
    date, clock, frac, tz = m.group(1), m.group(2), m.group(3) or "", m.group(4) or ""
    if frac:
        frac = (frac + "000000")[:7]          # ".1234567" -> ".123456"
    if tz == "Z":
        tz = "+00:00"
    elif tz and ":" not in tz and len(tz) == 5:   # "+0800" -> "+08:00"
        tz = tz[:3] + ":" + tz[3:]
    try:
        return datetime.fromisoformat(date + "T" + clock + frac + tz)
    except Exception:
        return None


def human_age(iso):
    dt = parse_iso(iso)
    if not dt:
        return ""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    secs = (datetime.now(timezone.utc) - dt).total_seconds()
    if secs < 0:
        return "刚刚"
    if secs < 60:
        return "%d 秒前" % secs
    if secs < 3600:
        return "%d 分钟前" % (secs // 60)
    if secs < 86400:
        return "%.1f 小时前" % (secs / 3600)
    return "%.1f 天前" % (secs / 86400)


def human_duration(secs):
    if secs is None or secs < 0:
        return "-"
    secs = int(secs)
    if secs < 60:
        return "%ds" % secs
    if secs < 3600:
        return "%dm%02ds" % (secs // 60, secs % 60)
    return "%dh%02dm" % (secs // 3600, (secs % 3600) // 60)


# ==================================================================== Tailscale
def tailscale_status():
    def probe():
        if OFFLINE:
            return {"ok": False, "error": "离线模式", "peers": [], "self": None}
        exe = _expand(CONFIG.get("tailscale_exe") or "")
        if not exe or not os.path.isfile(exe):
            exe = shutil.which("tailscale") or shutil.which("tailscale.exe") or ""
        if not exe:
            return {"ok": False, "error": "未找到 tailscale 可执行文件（改配置 tailscale_exe）",
                    "peers": [], "self": None}
        try:
            out = subprocess.run([exe, "status", "--json"], capture_output=True,
                                 timeout=20, creationflags=NO_WINDOW)
            if out.returncode != 0:
                msg = out.stderr.decode("utf-8", "replace").strip()
                return {"ok": False, "error": msg or "tailscale status 返回 %d" % out.returncode,
                        "peers": [], "self": None}
            d = json.loads(out.stdout.decode("utf-8", "replace") or "{}")
        except Exception as e:
            return {"ok": False, "error": "%s: %s" % (type(e).__name__, e), "peers": [], "self": None}

        prefix = str(CONFIG.get("machine_prefix") or "")
        peers = []
        for _, v in (d.get("Peer") or {}).items():
            if not isinstance(v, dict):
                continue
            host = v.get("HostName") or ""
            if prefix and not host.startswith(prefix):
                continue
            ips = v.get("TailscaleIPs") or []
            peers.append({
                "hostname": host,
                "ip": ips[0] if ips else "",
                "online": bool(v.get("Online")),
                "active": bool(v.get("Active")),
                "os": v.get("OS") or "",
                "last_seen": v.get("LastSeen") or "",
                "last_seen_human": "" if v.get("Online") else human_age(v.get("LastSeen")),
                "rx": v.get("RxBytes") or 0,
                "tx": v.get("TxBytes") or 0,
            })
        peers.sort(key=lambda p: (not p["online"], p["hostname"]))
        self_ = d.get("Self") or {}
        self_ips = self_.get("TailscaleIPs") or []
        return {
            "ok": True,
            "peers": peers,
            "self": {"hostname": self_.get("HostName") or "",
                     "ip": self_ips[0] if self_ips else "",
                     "online": True},
        }
    return cached("tailscale", CONFIG["cache_seconds"], probe)


# ==================================================================== SMB（读远端机器状态）
def _unc(ip, rel):
    share = CONFIG.get("smb_share") or "D$"
    base = str(CONFIG.get("smb_base") or r"D:\cloudrdp-sys")
    tail = base.split(":", 1)[1].lstrip("\\/") if ":" in base else base.lstrip("\\/")
    return "\\\\%s\\%s\\%s\\%s" % (ip, share, tail, rel.replace("/", "\\"))


_SMB_DONE = set()


def _smb_preauth(ip):
    """Windows 下用 net use 预建会话，让后续 open(UNC) 能通过鉴权。"""
    if not IS_WINDOWS:
        return False
    try:
        share = "\\\\%s\\%s" % (ip, CONFIG.get("smb_share") or "D$")
        subprocess.run(["net", "use", share, "/user:" + str(CONFIG.get("rdp_user") or "a"),
                        str(CONFIG.get("rdp_password") or "a")],
                       capture_output=True, timeout=25, creationflags=NO_WINDOW)
        return True
    except Exception:
        return False


def read_remote_text(ip, rel):
    """读远端机器上 D:\\cloudrdp-sys 下的文本文件。失败抛异常。"""
    p = _unc(ip, rel)
    err = None
    for attempt in (0, 1):
        try:
            with open(p, "r", encoding="utf-8-sig", errors="replace") as f:
                return f.read()
        except Exception as e:
            err = e
            if attempt == 0 and ip not in _SMB_DONE and _smb_preauth(ip):
                _SMB_DONE.add(ip)
                continue
            break
    raise err


def parse_pool_info(text):
    """解析机器上 _state/pool-info.txt（`key=value` 行）→ dict。空文本/坏行都跳过。"""
    out = {}
    for line in (text or "").splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def map_machine_accounts(machines, account_list):
    """给每台机器补 account_id：机器自报的 pool_owner → 账号池里的 id（找不到留空）。

    就地修改并返回 machines；owner 未知（老机器/单机）时 account_id 为空串。
    """
    owner2id = {}
    for a in (account_list or []):
        owner = str(a.get("owner") or "")
        if owner:
            owner2id[owner] = a.get("id") or ""
    for m in machines:
        m["account_id"] = owner2id.get(str(m.get("pool_owner") or ""), "")
    return machines


def machine_detail(ip, online):
    """读单台机器的池角色 + 快照新鲜度 + 运行时长 + 归属账号。任何一项读不到就留空，不抛。"""
    detail = {"role": "", "role_source": "", "snapshot": None, "error": "",
              "started_utc": "", "uptime_seconds": None, "uptime_human": "",
              "pool_owner": "", "pool_id": "", "assigned_role": ""}
    if OFFLINE or not ip or not online:
        return detail
    try:
        role = (read_remote_text(ip, "_state/pool-role.txt") or "").strip().lower()
        if role:
            detail["role"] = role
            detail["role_source"] = "本机 _state/pool-role.txt"
    except Exception as e:
        detail["error"] = "读角色失败：%s" % e
    try:
        raw = read_remote_text(ip, "_snapshot/manifest.json")
        man = json.loads(raw)
        files = man.get("file_count") or man.get("files") or man.get("count")
        when = man.get("created_utc") or man.get("created") or man.get("time") or man.get("updated_utc")
        size = man.get("total_bytes") or man.get("bytes")
        age_min = None
        dt = parse_iso(when)
        if dt:
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            age_min = (datetime.now(timezone.utc) - dt).total_seconds() / 60.0
        detail["snapshot"] = {
            "ok": True,
            "created": when,
            "age_human": human_age(when),
            "age_minutes": age_min,
            "files": files,
            "bytes": size,
            "stale": (age_min is not None and age_min > float(CONFIG.get("snapshot_stale_minutes") or 90)),
        }
    except Exception:
        detail["snapshot"] = {"ok": False}
    # 运行时长：workflow 第 0a 步写入的 _state\job-start.txt（ISO-8601 UTC）→ now - 起点
    try:
        raw = (read_remote_text(ip, "_state/job-start.txt") or "").strip()
        dt = parse_iso(raw)
        if dt:
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            up = (datetime.now(timezone.utc) - dt).total_seconds()
            if up >= 0:
                detail["started_utc"] = raw
                detail["uptime_seconds"] = int(up)
                detail["uptime_human"] = human_duration(up)
    except Exception:
        pass
    # 归属账号：机器上 _state\pool-info.txt 记录派发它的账号（pool_owner）—— 池模式才有
    try:
        info = parse_pool_info(read_remote_text(ip, "_state/pool-info.txt"))
        detail["pool_owner"] = info.get("pool_owner", "")
        detail["pool_id"] = info.get("pool_id", "")
        detail["assigned_role"] = info.get("assigned_role", "")
    except Exception:
        pass
    return detail


# ==================================================================== 账号池
def load_pool_config():
    p = pool_config_path()
    if not os.path.isfile(p):
        return {"ok": False, "error": "找不到账号池配置：%s" % p, "path": p, "config": None}
    try:
        with open(p, "r", encoding="utf-8-sig") as f:
            return {"ok": True, "path": p, "config": json.load(f)}
    except Exception as e:
        return {"ok": False, "error": "解析失败：%s" % e, "path": p, "config": None}


def save_pool_config(cfg):
    """原子写回账号池配置（保留缩进与中文）。"""
    p = pool_config_path()
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, p)


def get_secret_names():
    """仓库里已配置的 Actions Secret 名字集合（拿不到就返回 None）。"""
    def probe():
        if OFFLINE:
            return None
        repo = CONFIG.get("repo") or ""
        try:
            d = gh_api("/repos/%s/actions/secrets?per_page=100" % repo)
            names = [s.get("name") for s in (d.get("secrets") or []) if s.get("name")]
            return set(names)
        except Exception:
            return None
    return cached("secrets", max(60, CONFIG["cache_seconds"]), probe)


def get_pool_state():
    """读 hub 发布在 pool-state 分支上的权威状态。

    先走 raw.githubusercontent.com（匿名免 token，最快），
    失败则回退到 GitHub API 的 contents 接口（走 api.github.com，国内更稳）。
    """
    def probe():
        if OFFLINE:
            return {"ok": False, "error": "离线模式", "state": None}
        repo = CONFIG.get("repo") or ""
        branch = CONFIG.get("state_branch") or "pool-state"
        path = CONFIG.get("state_path") or "state/pool-state.json"
        errs = []

        # ① raw（匿名）
        try:
            d = http_json("https://raw.githubusercontent.com/%s/%s/%s" % (repo, branch, path),
                          timeout=20)
            return {"ok": True, "error": "", "state": d, "via": "raw", "fetched_at": now_iso()}
        except Exception as e:
            errs.append("raw: %s: %s" % (type(e).__name__, e))

        # ② GitHub API contents（需要 token；公开仓库匿名也行，但限流低）
        try:
            d = gh_api("/repos/%s/contents/%s" % (repo, path), params={"ref": branch})
            content = d.get("content") or ""
            text = base64.b64decode(content).decode("utf-8") if content else ""
            state = json.loads(text) if text.strip() else {}
            return {"ok": True, "error": "", "state": state, "via": "api", "fetched_at": now_iso()}
        except Exception as e:
            errs.append("api: %s: %s" % (type(e).__name__, e))

        return {"ok": False, "error": "; ".join(errs), "state": None}
    return cached("pool_state", CONFIG["cache_seconds"], probe)


def pool_account_reports(state):
    """把 pool-state 里的 accounts 明细整理成 owner -> 明细 的映射。

    兼容三种形态：list / 单条 dict（个别 PowerShell 版本会把单元素数组压扁）/ 缺失。
    """
    raw = (state or {}).get("accounts")
    if isinstance(raw, dict):
        raw = [raw]
    out = {}
    for r in (raw or []):
        if not isinstance(r, dict):
            continue
        owner = str(r.get("owner") or "")
        if owner:
            out[owner] = r
    return out


def shape_last_run(r):
    """把「最近一次 run」统一成一种形状 —— 兼容 pool-state 明细与 Actions runs 两种来源。"""
    if not r:
        return None
    return {
        "id": r.get("run_id") if r.get("run_id") is not None else r.get("id"),
        "state": r.get("state") or r.get("conclusion") or r.get("status") or "",
        "conclusion": r.get("conclusion") or "",
        "status": r.get("status") or "",
        "created_at": r.get("created_at") or "",
        "created_human": human_age(r.get("created_at") or ""),
        "event": r.get("event") or "",
        "url": r.get("url") or "",
    }


def hub_live_probe(owner, repo_name):
    """hub 账号 = 工作台自己配的那个仓库。

    对 hub 账号可以拿本机 token 实时探测（复用已缓存的 runs，不额外发请求），
    比协调器 10 分钟一次的结果新鲜得多。非 hub 账号返回 None（只能靠 pool-state）。
    """
    cfg_repo = str(CONFIG.get("repo") or "")
    if "/" not in cfg_repo:
        return None
    h_owner, h_repo = cfg_repo.split("/", 1)
    if str(owner) != h_owner or str(repo_name) != h_repo:
        return None
    try:
        runs = get_runs(workflow_key="keepalive")
    except Exception:
        return None
    if not runs.get("ok"):
        return None
    rows = runs.get("keepalive") or []
    return {"alive_count": len([r for r in rows if r.get("in_progress")]),
            "last_run": (rows[0] if rows else None)}


def get_accounts():
    """账号池账号清单：合并 Secret 就位情况 + pool-state 每账号巡检明细 + 在跑机。

    实时状态监测的数据来源（按可信度排序）：
      * live        —— hub 账号：用本机 token 直接查 Actions runs（最新）
      * pool-state  —— 协调器每 10 分钟巡检后发布的权威明细（覆盖所有账号）
      * none        —— 还没有任何数据（协调器还没跑过 / 状态分支还没生成）
    """
    pc = load_pool_config()
    if not pc["ok"]:
        return {"ok": False, "error": pc["error"], "path": pc["path"], "accounts": []}
    cfg = pc["config"] or {}
    secrets = get_secret_names()
    pool = get_pool_state()
    state = pool.get("state") or {}
    reports = pool_account_reports(state)

    # owner -> 池状态条目（primary / standby）
    by_owner = {}
    if isinstance(state.get("primary"), dict):
        pr = state["primary"]
        by_owner[str(pr.get("owner") or "")] = dict(pr, role="primary")
    for st in (state.get("standby") or []):
        if isinstance(st, dict):
            by_owner.setdefault(str(st.get("owner") or ""), dict(st, role="standby"))

    accounts = []
    for a in (cfg.get("accounts") or []):
        owner = str(a.get("owner") or "")
        secret = str(a.get("token_secret") or "")
        repo_name = str(a.get("repo") or "")
        enabled = a.get("enabled") is not False
        alive = by_owner.get(owner) or {}
        rep = reports.get(owner) or {}

        source = "pool-state" if rep else "none"
        alive_count = rep.get("alive_count")
        last_run = shape_last_run(rep.get("last_run"))

        # hub 账号：实时探测（复用缓存，几乎零成本）
        if enabled:
            live = hub_live_probe(owner, repo_name)
            if live:
                alive_count = live["alive_count"]
                last_run = shape_last_run(live["last_run"])
                source = "live"

        # 凭证是否就位：三条线索，按可信度取（Secret 值永不回显，只能看名字 + 协调器巡检结果）
        #   ① pool-state 的 token_state=ok —— 协调器真的解析并用了该 token（最可信）
        #   ② 精确 Secret 名存在 —— 每账号一个 Secret 的通道
        #   ③ 存在 POOL_TOKENS（JSON 通道）—— 值不可读，无法确认是否含本账号 → 存疑（None）
        if secrets is None:
            secret_via = ""
        elif secret and secret in secrets:
            secret_via = "secret"
        elif "POOL_TOKENS" in secrets:
            secret_via = "pool_tokens"
        else:
            secret_via = "none"
        if rep.get("token_state") == "ok":
            secret_present = True
        elif secrets is None:
            secret_present = None
        elif secret and secret in secrets:
            secret_present = True
        elif "POOL_TOKENS" in secrets:
            secret_present = None
        else:
            secret_present = False

        accounts.append({
            "id": a.get("id") or "",
            "owner": owner,
            "repo": repo_name,
            "enabled": enabled,
            "token_secret": secret,
            "secret_present": secret_present,
            "secret_via": secret_via,
            "alive": bool(alive) or bool(alive_count),
            "role": str(rep.get("role") or alive.get("role") or ""),
            "run_id": alive.get("run_id"),
            "since": alive.get("since") or "",
            "since_human": human_age(alive.get("since") or ""),
            "placeholder": owner.startswith("REPLACE_"),
            # ---- 实时状态监测 ----
            "token_state": str(rep.get("token_state") or ""),
            "alive_count": alive_count,
            "last_run": last_run,
            "report_note": str(rep.get("note") or ""),
            "source": source,
        })

    return {"ok": True, "error": "", "path": pc["path"],
            "pool_id": cfg.get("pool_id") or "",
            "target_machines": cfg.get("target_machines"),
            "hub": cfg.get("hub") or {},
            "accounts": accounts,
            "secrets_readable": secrets is not None,
            # 监测数据新鲜度（来自 pool-state）
            "state_updated": state.get("updated_utc") or "",
            "state_age_human": human_age(state.get("updated_utc") or ""),
            "state_via": pool.get("via") or "",
            "monitor_available": bool(reports)}


# ==================================================================== Actions runs
def _shape_run(r):
    created = r.get("created_at") or ""
    updated = r.get("updated_at") or ""
    status = r.get("status") or ""
    conclusion = r.get("conclusion") or ""
    dur = None
    a, b = parse_iso(r.get("run_started_at") or created), parse_iso(updated)
    if a and b:
        dur = (b - a).total_seconds()
    return {
        "id": r.get("id"),
        "number": r.get("run_number"),
        "title": r.get("display_title") or r.get("name") or "",
        "workflow": r.get("name") or "",
        "path": (r.get("path") or "").split("/")[-1],
        "event": r.get("event") or "",
        "status": status,
        "conclusion": conclusion,
        "state": conclusion if conclusion else status,
        "created_at": created,
        "created_human": human_age(created),
        "updated_at": updated,
        "updated_human": human_age(updated),
        "duration": human_duration(dur),
        "duration_seconds": dur,
        "head_sha": (r.get("head_sha") or "")[:8],
        "branch": r.get("head_branch") or "",
        "actor": (r.get("actor") or {}).get("login") or "",
        "url": r.get("html_url") or "",
        "in_progress": status in ("in_progress", "queued", "waiting", "requested", "pending"),
    }


def get_runs(limit=None, workflow_key=None):
    """拉两个 workflow 的最近 run。workflow_key 为 None 表示两个都要。"""
    # 注意：n 必须单独命名 —— 若在 probe() 里写 limit = ...，
    # 会让 limit 变成 probe 的局部变量，右侧读它即 UnboundLocalError。
    n = int(limit or CONFIG.get("run_limit") or 25)

    def probe():
        if OFFLINE:
            return {"ok": False, "error": "离线模式", "keepalive": [], "coordinator": []}
        repo = CONFIG.get("repo") or ""
        out = {"ok": True, "error": "", "keepalive": [], "coordinator": []}
        targets = (workflow_key,) if workflow_key else ("keepalive", "coordinator")
        for key in targets:
            wf = (CONFIG.get("workflows") or {}).get(key)
            if not wf:
                continue
            try:
                d = gh_api("/repos/%s/actions/workflows/%s/runs" % (repo, wf),
                           params={"per_page": min(n, 100)})
                out[key] = [_shape_run(r) for r in (d.get("workflow_runs") or [])]
            except Exception as e:
                out["error"] = "%s: %s" % (key, e)
                out["ok"] = False
        return out
    return cached("runs:%s:%s" % (workflow_key or "all", n),
                  CONFIG["cache_seconds"], probe)


def dispatch_workflow(workflow_key, inputs=None, ref=None):
    """触发一个 workflow_dispatch。返回 {ok, error}。"""
    wf = (CONFIG.get("workflows") or {}).get(workflow_key)
    if not wf:
        return {"ok": False, "error": "未知 workflow：%s" % workflow_key}
    repo = CONFIG.get("repo") or ""
    if not resolve_token():
        return {"ok": False, "error": "没有 GitHub Token，无法触发（配置 token_file 或设 GH_TOKEN）"}
    try:
        gh_api("/repos/%s/actions/workflows/%s/dispatches" % (repo, wf),
               method="POST",
               body={"ref": ref or CONFIG.get("ref") or "main",
                     "inputs": {k: str(v) for k, v in (inputs or {}).items()}})
        clear_cache()
        return {"ok": True, "error": "", "workflow": wf}
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:300]
        except Exception:
            pass
        return {"ok": False, "error": "HTTP %s %s" % (e.code, detail)}
    except Exception as e:
        return {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}


# ==================================================================== 一键登录
def rdp_dir():
    d = _expand(CONFIG.get("rdp_dir") or "")
    if not d:
        d = os.path.join(os.path.expanduser("~"), "Desktop")
    if not os.path.isdir(d):
        d = os.path.expanduser("~")
    return d


def build_rdp_text(ip, user):
    w = int(CONFIG.get("rdp_width") or 1920)
    h = int(CONFIG.get("rdp_height") or 1080)
    lines = [
        "screen mode id:i:2",
        "use multimon:i:0",
        "desktopwidth:i:%d" % w,
        "desktopheight:i:%d" % h,
        "session bpp:i:32",
        "compression:i:1",
        "keyboardhook:i:2",
        "audiocapturemode:i:0",
        "videoplaybackmode:i:1",
        "connection type:i:7",
        "networkautodetect:i:1",
        "bandwidthautodetect:i:1",
        "displayconnectionbar:i:1",
        "disable wallpaper:i:0",
        "allow font smoothing:i:1",
        "allow desktop composition:i:0",
        "disable full window drag:i:1",
        "disable menu anims:i:1",
        "disable themes:i:0",
        "disable cursor setting:i:0",
        "bitmapcachepersistenable:i:1",
        "full address:s:%s" % ip,
        "audiomode:i:0",
        "redirectprinters:i:0",
        "redirectcomports:i:0",
        "redirectsmartcards:i:1",
        "redirectclipboard:i:1",
        "redirectposdevices:i:0",
        "autoreconnection enabled:i:1",
        # 0 = 连接且不再弹「无法验证远程计算机身份」——tailnet 内网直连，省一次点击
        "authentication level:i:0",
        "prompt for credentials:i:0",
        "negotiate security layer:i:1",
        "enablecredsspsupport:i:1",
        "remoteapplicationmode:i:0",
        "alternate shell:s:",
        "shell working directory:s:",
        "gatewayhostname:s:",
        "gatewayusagemethod:i:4",
        "gatewaycredentialssource:i:4",
        "gatewayprofileusagemethod:i:0",
        "promptcredentialonce:i:0",
        "gatewaybrokeringtype:i:0",
        "use redirection server name:i:0",
        "rdgiskdcproxy:i:0",
        "kdcproxyname:s:",
        "drivestoredirect:s:",
        "username:s:%s" % user,
        "",
    ]
    return "\r\n".join(lines)


def store_credential(ip, user, password):
    if not IS_WINDOWS or not CONFIG.get("rdp_store_cred", True):
        return {"ok": False, "error": "非 Windows 或已关闭凭据预存"}
    try:
        out = subprocess.run(["cmdkey", "/generic:TERMSRV/%s" % ip, "/user:" + user,
                              "/pass:" + password],
                             capture_output=True, timeout=20, creationflags=NO_WINDOW)
        if out.returncode == 0:
            return {"ok": True, "error": ""}
        return {"ok": False, "error": out.stdout.decode("gbk", "replace").strip()
                or out.stderr.decode("gbk", "replace").strip()}
    except Exception as e:
        return {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}


def make_rdp(ip, hostname="", launch=None, store_cred=None):
    """生成 .rdp（可选预存凭据 / 唤起 mstsc）。"""
    ip = (ip or "").strip()
    if not re.match(r"^[0-9A-Za-z_.\-]+$", ip):
        return {"ok": False, "error": "IP 非法：%s" % ip}
    user = str(CONFIG.get("rdp_user") or "a")
    launch = CONFIG.get("rdp_launch", True) if launch is None else bool(launch)
    store_cred = CONFIG.get("rdp_store_cred", True) if store_cred is None else bool(store_cred)

    safe = re.sub(r"[^0-9A-Za-z_.\-]", "", hostname or ip) or ip
    path = os.path.join(rdp_dir(), "RDP-%s-%s.rdp" % (safe, ip))
    try:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(build_rdp_text(ip, user))
    except Exception as e:
        return {"ok": False, "error": "写 .rdp 失败：%s" % e}

    cred = {"ok": False, "error": "未预存"}
    if store_cred:
        cred = store_credential(ip, user, str(CONFIG.get("rdp_password") or "a"))

    launched = False
    launch_error = ""
    if launch:
        try:
            if IS_WINDOWS:
                os.startfile(path)  # noqa: S606
                launched = True
            else:
                launch_error = "非 Windows，已生成文件但未唤起客户端"
        except Exception as e:
            launch_error = "唤起失败：%s" % e
    return {"ok": True, "path": path, "ip": ip, "user": user,
            "cred_stored": cred.get("ok"), "cred_error": cred.get("error") or "",
            "launched": launched, "launch_error": launch_error}


# ==================================================================== 汇总
def build_overview():
    """一次拿齐前端需要的全部数据。各链路独立降级。"""
    errors = []
    pool_cfg = load_pool_config()
    gh = gh_ready()
    if not gh["ok"]:
        errors.append("GitHub：%s" % gh["detail"])

    with ThreadPoolExecutor(max_workers=4) as ex:
        f_ts = ex.submit(tailscale_status)
        f_runs = ex.submit(get_runs)
        f_acc = ex.submit(get_accounts)
        f_state = ex.submit(get_pool_state)

        ts = f_ts.result()
        runs = f_runs.result()
        accounts = f_acc.result()
        pool_state = f_state.result()

    if not ts.get("ok"):
        errors.append("Tailscale：%s" % ts.get("error"))
    if not runs.get("ok"):
        errors.append("Actions：%s" % runs.get("error"))
    if not accounts.get("ok"):
        errors.append("账号池：%s" % accounts.get("error"))
    if not pool_state.get("ok"):
        errors.append("池状态：%s" % pool_state.get("error"))

    # 机器实况：Tailscale 在线节点 + 每台的池角色 / 快照
    machines = []
    peers = ts.get("peers") or []
    if peers:
        with ThreadPoolExecutor(max_workers=6) as ex:
            details = list(ex.map(lambda p: machine_detail(p.get("ip"), p.get("online")), peers))
        for p, d in zip(peers, details):
            machines.append(dict(p, **d))

    # 机器归属账号：pool_owner → 账号池 id（前端「主机」列展示「账号 · owner」）
    map_machine_accounts(machines, accounts.get("accounts") or [])

    online = [m for m in machines if m.get("online")]
    primary = [m for m in machines if m.get("role") == "primary"]
    standby = [m for m in machines if m.get("role") == "standby"]

    return {
        "ok": True,
        "version": VERSION,
        "started_at": STARTED_AT,
        "generated_at": now_iso(),
        "config": {
            "repo": CONFIG.get("repo"),
            "ref": CONFIG.get("ref"),
            "token_present": bool(resolve_token()),
            "proxy": _proxy_url() or "直连",
            "auto_refresh_seconds": CONFIG.get("auto_refresh_seconds"),
            "machine_prefix": CONFIG.get("machine_prefix"),
            "target_machines": (accounts.get("target_machines")
                                if accounts.get("ok") else None),
            "pool_config_path": pool_cfg.get("path"),
        },
        "stats": {
            "machines_online": len(online),
            "machines_total": len(machines),
            "machines_primary": len(primary),
            "machines_standby": len(standby),
            "accounts_total": len(accounts.get("accounts") or []),
            "accounts_enabled": len([a for a in (accounts.get("accounts") or []) if a.get("enabled")]),
            "target_machines": accounts.get("target_machines"),
        },
        "accounts": accounts,
        "machines": machines,
        "pool_state": pool_state,
        "runs": runs,
        "errors": errors,
    }


# ==================================================================== HTTP 服务
MIME = {".html": "text/html; charset=utf-8",
        ".js": "application/javascript; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".json": "application/json; charset=utf-8",
        ".svg": "image/svg+xml",
        ".ico": "image/x-icon",
        ".png": "image/png"}


class Handler(BaseHTTPRequestHandler):
    server_version = "Workbench/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if not QUIET:
            sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    # ---------- 工具 ----------
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        raw = self.rfile.read(n).decode("utf-8", "replace")
        try:
            return json.loads(raw) if raw.strip() else {}
        except Exception:
            return {}

    # ---------- 路由 ----------
    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def do_HEAD(self):
        # 浏览器/预览面板探活会先发 HEAD；不支持会返回 501，被误判成「服务不可用」。
        self._route("HEAD")

    def handle_error(self, request, client_address):
        # 探活（HEAD）后立刻断开是常态，别把 ConnectionReset 当成异常刷屏。
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, ConnectionAbortedError, BrokenPipeError)):
            return
        return super().handle_error(request, client_address)

    def _route(self, method):
        path, _, query = self.path.partition("?")
        params = urllib.parse.parse_qs(query)
        lookup = "GET" if method == "HEAD" else method   # HEAD 复用 GET 的处理器，_send 不写 body
        try:
            if not path.startswith("/api/"):
                if lookup != "GET":
                    return self._json(405, {"ok": False, "error": "method not allowed"})
                return self._static(path)
            fn = ROUTES.get((lookup, path))
            if not fn:
                return self._json(404, {"ok": False, "error": "no such api: %s %s" % (method, path)})
            fn(self, params)
        except Exception as e:
            self._json(500, {"ok": False, "error": "%s: %s" % (type(e).__name__, e)})

    # ---------- 静态 ----------
    def _static(self, path):
        if path in ("/", "", "/index.html"):
            rel = "index.html"
        elif path == "/favicon.ico":
            return self._send(204, b"", "image/x-icon")
        else:
            rel = path.lstrip("/")
        full = os.path.normpath(os.path.join(STATIC_DIR, rel))
        if not full.startswith(STATIC_DIR) or not os.path.isfile(full):
            return self._send(404, "not found", "text/plain; charset=utf-8")
        ext = os.path.splitext(full)[1].lower()
        with open(full, "rb") as f:
            data = f.read()
        return self._send(200, data, MIME.get(ext, "application/octet-stream"))


# ==================================================================== API 实现
def api_health(h, params):
    gh = gh_ready()
    h._json(200, {"ok": True, "version": VERSION, "started_at": STARTED_AT, "time": now_iso(),
                  "repo": CONFIG.get("repo"), "token_present": bool(resolve_token()),
                  "github": gh, "offline": OFFLINE})


def api_overview(h, params):
    if "refresh" in params:
        clear_cache()
        resolve_token(force=True)
    h._json(200, build_overview())


def api_accounts(h, params):
    h._json(200, get_accounts())


def api_accounts_toggle(h, params):
    body = h._read_body()
    acc_id = str(body.get("id") or "")
    enabled = body.get("enabled")
    if not acc_id or enabled is None:
        return h._json(400, {"ok": False, "error": "需要 id 与 enabled"})
    pc = load_pool_config()
    if not pc["ok"]:
        return h._json(400, {"ok": False, "error": pc["error"]})
    cfg = pc["config"]
    hit = None
    for a in (cfg.get("accounts") or []):
        if str(a.get("id")) == acc_id:
            a["enabled"] = bool(enabled)
            hit = a
            break
    if not hit:
        return h._json(404, {"ok": False, "error": "找不到账号 %s" % acc_id})
    try:
        save_pool_config(cfg)
    except Exception as e:
        return h._json(500, {"ok": False, "error": "写回失败：%s" % e})
    clear_cache()
    return h._json(200, {"ok": True, "id": acc_id, "enabled": bool(enabled),
                         "path": pc["path"]})


_RE_OWNER = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
_RE_REPO = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
_RE_SECRET = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,99}$")
_RE_ACCID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def verify_repo_exists(owner, repo):
    """用本机 token 校验仓库是否存在。返回 (state, note)：
    'ok'（存在）/ 'missing'（明确 404）/ 'unknown'（离线或网络异常，不拦）。"""
    if OFFLINE:
        return "unknown", "离线模式，跳过仓库校验"
    try:
        gh_api("/repos/%s/%s" % (owner, repo), timeout=15)
        return "ok", ""
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return "missing", "仓库 %s/%s 不存在（或本机 token 无权访问）" % (owner, repo)
        return "unknown", "仓库校验未完成：GitHub API %s" % e.code
    except Exception as e:
        return "unknown", "仓库校验未完成：%s: %s" % (type(e).__name__, e)


def api_accounts_add(h, params):
    """新增账号：写回 pool-config.json（原子写）。PAT 绝不进本文件。"""
    body = h._read_body()
    owner = str(body.get("owner") or "").strip()
    repo = str(body.get("repo") or "cloud-rdp").strip()
    secret = str(body.get("token_secret") or "").strip()
    acc_id = str(body.get("id") or "").strip()
    enabled = body.get("enabled")
    if enabled is None:
        enabled = True

    errs = []
    if not owner:
        errs.append("owner（GitHub 用户名）必填")
    elif not _RE_OWNER.match(owner):
        errs.append("owner 格式不合法（GitHub 用户名：字母数字与连字符）")
    if not repo:
        errs.append("repo（仓库名）必填")
    elif not _RE_REPO.match(repo):
        errs.append("repo 名不合法")
    if not secret:
        errs.append("token_secret（Secret 名）必填")
    elif not _RE_SECRET.match(secret):
        errs.append("token_secret 必须是合法 Secret 名（字母/下划线开头，仅含字母数字下划线）")
    if acc_id and not _RE_ACCID.match(acc_id):
        errs.append("id 不合法（字母数字与 . _ -）")
    if errs:
        return h._json(400, {"ok": False, "error": "；".join(errs)})

    pc = load_pool_config()
    if not pc["ok"]:
        return h._json(400, {"ok": False, "error": pc["error"]})
    cfg = pc["config"] or {}
    accs = cfg.get("accounts")
    if not isinstance(accs, list):
        accs = []
        cfg["accounts"] = accs

    for a in accs:
        if str(a.get("owner") or "").lower() == owner.lower():
            return h._json(409, {"ok": False, "error": "账号 %s 已存在" % owner})
    if acc_id:
        for a in accs:
            if str(a.get("id") or "") == acc_id:
                return h._json(409, {"ok": False, "error": "id %s 已存在" % acc_id})

    # 仓库校验：明确 404 才拦；离线/网络异常放行（只提示），避免误伤
    v_state, v_note = verify_repo_exists(owner, repo)
    if v_state == "missing":
        return h._json(400, {"ok": False, "error": v_note})

    if not acc_id:
        existing = set(str(a.get("id") or "") for a in accs)
        n = 1
        while ("acc-%d" % n) in existing:
            n += 1
        acc_id = "acc-%d" % n

    entry = {"id": acc_id, "owner": owner, "repo": repo,
             "token_secret": secret, "enabled": bool(enabled)}
    accs.append(entry)
    try:
        save_pool_config(cfg)
    except Exception as e:
        return h._json(500, {"ok": False, "error": "写回失败：%s" % e})
    clear_cache()

    hint = ("PAT 不会写进本文件。请到 GitHub 仓库 Secrets 配置其一："
            "① 推荐 —— Secret 名 POOL_TOKENS，值是 JSON，加一项 \"%s\": \"ghp_...\"；"
            "② 或建名为 %s 的 Secret，值就是该账号的 PAT。" % (owner, secret))
    return h._json(200, {"ok": True, "id": acc_id, "account": entry,
                         "path": pc["path"], "verified": v_state,
                         "verify_note": v_note, "hint": hint})


def api_machines(h, params):
    ts = tailscale_status()
    machines = []
    for p in (ts.get("peers") or []):
        machines.append(dict(p, **machine_detail(p.get("ip"), p.get("online"))))
    h._json(200, {"ok": ts.get("ok", False), "error": ts.get("error", ""),
                  "self": ts.get("self"), "machines": machines})


def api_runs(h, params):
    key = (params.get("workflow") or [None])[0]
    if key in ("", "all"):
        key = None
    limit = (params.get("limit") or [None])[0]
    h._json(200, get_runs(limit=int(limit) if limit else None, workflow_key=key))


def api_pool_state(h, params):
    h._json(200, get_pool_state())


def api_dispatch(h, params):
    body = h._read_body()
    target = str(body.get("target") or "")
    inputs = body.get("inputs") or {}
    if target not in ("keepalive", "coordinator"):
        return h._json(400, {"ok": False, "error": "target 必须是 keepalive 或 coordinator"})
    if target == "coordinator" and not inputs:
        inputs = {"dry_run": "false"}
    res = dispatch_workflow(target, inputs)
    res["target"] = target
    res["inputs"] = inputs
    return h._json(200 if res["ok"] else 502, res)


def api_rdp(h, params):
    body = h._read_body()
    res = make_rdp(body.get("ip") or "", body.get("hostname") or "",
                   launch=body.get("launch"), store_cred=body.get("store_cred"))
    return h._json(200 if res.get("ok") else 400, res)


def api_rdp_preview(h, params):
    ip = (params.get("ip") or [""])[0]
    user = str(CONFIG.get("rdp_user") or "a")
    h._send(200, build_rdp_text(ip, user), "text/plain; charset=utf-8")


def api_conn_info(h, params):
    """连接信息（Tailscale IP / 用户名 / 密码）。仅供本机仪表盘「查看信息」用。"""
    ip = (params.get("ip") or [""])[0]
    h._json(200, {
        "ok": True,
        "ip": ip,
        "username": str(CONFIG.get("rdp_user") or "a"),
        "password": str(CONFIG.get("rdp_password") or "a"),
        "store_cred": bool(CONFIG.get("rdp_store_cred", True)),
        "rdp_width": int(CONFIG.get("rdp_width") or 1920),
        "rdp_height": int(CONFIG.get("rdp_height") or 1080),
    })


ROUTES = {
    ("GET", "/api/health"): api_health,
    ("GET", "/api/overview"): api_overview,
    ("GET", "/api/accounts"): api_accounts,
    ("POST", "/api/accounts/toggle"): api_accounts_toggle,
    ("POST", "/api/accounts/add"): api_accounts_add,
    ("GET", "/api/machines"): api_machines,
    ("GET", "/api/runs"): api_runs,
    ("GET", "/api/pool-state"): api_pool_state,
    ("POST", "/api/dispatch"): api_dispatch,
    ("POST", "/api/rdp"): api_rdp,
    ("GET", "/api/rdp/preview"): api_rdp_preview,
    ("GET", "/api/conn-info"): api_conn_info,
}


# ==================================================================== main
def main(argv=None):
    global OFFLINE, QUIET, CONFIG
    ap = argparse.ArgumentParser(description="GitHub 虚拟机管理工作台（本地 Web 仪表盘）")
    ap.add_argument("--host", default=None)
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--config", default=None, help="配置文件路径（默认 workbench/config.json）")
    ap.add_argument("--offline", action="store_true", help="离线模式：不联网，自测用")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--no-open", action="store_true", help="不自动打开浏览器")
    args = ap.parse_args(argv)

    OFFLINE = bool(args.offline)
    QUIET = bool(args.quiet)
    CONFIG = load_config(args.config)
    if args.host:
        CONFIG["host"] = args.host
    if args.port:
        CONFIG["port"] = args.port
    if args.no_open:
        CONFIG["open_browser"] = False

    host, port = CONFIG["host"], int(CONFIG["port"])
    srv = ThreadingHTTPServer((host, port), Handler)
    srv.daemon_threads = True
    url = "http://%s:%d/" % (host, port)

    print("=" * 62)
    print(" GitHub 虚拟机管理工作台  v%s" % VERSION)
    print("  地址    : %s" % url)
    print("  仓库    : %s (%s)" % (CONFIG.get("repo"), CONFIG.get("ref")))
    print("  Token   : %s" % ("已发现" if resolve_token() else "未发现（部分面板会降级）"))
    print("  代理    : %s" % (_proxy_url() or "直连"))
    print("  模式    : %s" % ("离线（自测）" if OFFLINE else "在线"))
    print("  账号池  : %s" % pool_config_path())
    print("  Ctrl+C 停止")
    print("=" * 62)

    if CONFIG.get("open_browser"):
        def _open():
            time.sleep(0.8)
            try:
                import webbrowser
                webbrowser.open(url)
            except Exception:
                pass
        threading.Thread(target=_open, daemon=True).start()

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
