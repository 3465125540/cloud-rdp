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
    python workbench/server.py                 # 默认 http://127.0.0.1:8899
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
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.5.0"
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
    "port": 8899,
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
    # 平台默认：Windows 走官方安装路径；Linux 用 PATH 里的 tailscale（找不到会自动 which）
    "tailscale_exe": (r"C:\Program Files\Tailscale\tailscale.exe" if IS_WINDOWS else "tailscale"),
    "machine_prefix": "github-rdp-server",   # 只把以此开头的 Tailscale 节点当「我们的机器」
    "smb_share": "D$",
    "smb_base": r"D:\cloudrdp-sys",          # 远端系统目录（含 _state / _snapshot）
    "data_dir": r"D:\a\cloud-rdp",           # 远端数据目录（与 139 云盘同步；读旧标记文件时用）
    "snapshot_stale_minutes": 90,            # 快照超过这么久没更新 → 标记为「陈旧」
    # 读远端文件的方式：auto=Windows 用 UNC 直读、Linux 用 smbclient；
    # 也可强制 "unc" / "smbclient"。Linux 上 smbclient 需 `apt install smbclient`。
    "smb_mode": "auto",
    "smbclient_exe": "smbclient",
    "smb_timeout": 25,

    # ---- 一键备份（写请求文件 → 机器保活循环取走执行）----
    "backup_request_file": "_state/backup-request.txt",
    "backup_done_file": "_state/backup-done.txt",

    # ---- 访问控制（部署到服务器时强烈建议设置）----
    # 非空 = 所有请求都要带 token（?token=xxx 或 X-Workbench-Token 头）。
    # 工作台会把 RDP 明文密码经 /api/conn-info 返回，暴露到公网极危险。
    "access_token": "",

    # ---- 一键登录 ----
    "rdp_user": "a",
    "rdp_password": "a",
    "rdp_dir": "",                           # 留空 = ~/Documents/CloudRDP（不再写桌面）
    "rdp_width": 1920,
    "rdp_height": 1080,
    "rdp_launch": True,                      # 生成后是否自动唤起 mstsc
    "rdp_store_cred": True,                  # 是否 cmdkey 预存凭据（实现免手输密码）
    # 唤起方式：
    #   "mstsc" = 走 `mstsc /v:<ip>` 命令行（手动连接）—— 2026-04 KB5083769/CVE-2026-26151 之后，
    #             **只有打开 .rdp 文件**才会弹「安全警告 / 资源勾选」阻断框；手动连接不受影响。
    #             配合把 Default.rdp 的 authentication level 置 0，证书警告也一并消失 → 零弹窗。
    #   "file"  = 老行为：os.startfile(.rdp)，会被 KB5083769 的安全警告挡住。
    "rdp_launch_mode": "mstsc",
    # Linux 专用：唤起 RDP 客户端的命令模板（留空 = 自动探测 xfreerdp / remmina）。
    # 可用占位符：{ip} {user} {password} {file}。例：
    #   "xfreerdp /v:{ip} /u:{user} /p:{password} /cert:ignore /dynamic-resolution"
    #   "remmina -c {file}"
    "rdp_client_cmd": "",
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


# 北京时区（UTC+8）。仪表盘统一按北京时间展示绝对时间。
BEIJING_TZ = timezone(timedelta(hours=8))


def beijing_time(iso, fmt=None):
    """把 ISO 时间转成北京时区（UTC+8）的绝对时间字符串，默认形如 "2026/9/22-20:16"。

    用于「实时北京时间」展示：相比 human_age 的相对描述（如「3.7 小时前」），
    绝对时间不随页面停留而失真，也便于一眼对表。无时区信息时按 UTC 处理。
    默认格式手写拼接（不用 %-m / %-d）以兼容 Windows 的 strftime。
    """
    dt = parse_iso(iso)
    if not dt:
        return ""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    dt = dt.astimezone(BEIJING_TZ)
    if fmt:
        return dt.strftime(fmt)
    return "%d/%d/%d-%02d:%02d" % (dt.year, dt.month, dt.day, dt.hour, dt.minute)


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


# ==================================================================== 远端文件（SMB）
# Windows：直接 open("\\\\ip\\D$\\...")（先 net use 预鉴权）
# Linux  ：走 smbclient（子进程），把远端文件 get/put 到本机临时文件
def _unc(ip, rel):
    share = CONFIG.get("smb_share") or "D$"
    base = str(CONFIG.get("smb_base") or r"D:\cloudrdp-sys")
    tail = base.split(":", 1)[1].lstrip("\\/") if ":" in base else base.lstrip("\\/")
    return "\\\\%s\\%s\\%s\\%s" % (ip, share, tail, rel.replace("/", "\\"))


def _unc_abs(ip, abs_path):
    """远端绝对路径 → UNC。盘符决定共享名（`D:\\x` → `\\\\ip\\D$\\x`）。"""
    p = str(abs_path or "").replace("/", "\\")
    if len(p) >= 2 and p[1] == ":":
        share = p[0].upper() + "$"
        rest = p[2:].lstrip("\\")
    else:
        share = CONFIG.get("smb_share") or "D$"
        rest = p.lstrip("\\")
    return "\\\\%s\\%s\\%s" % (ip, share, rest)


def _rel_to_abs(rel):
    """`_state/pool-role.txt` → `D:\\cloudrdp-sys\\_state\\pool-role.txt`。"""
    base = str(CONFIG.get("smb_base") or r"D:\cloudrdp-sys").rstrip("\\/")
    return base + "\\" + str(rel or "").replace("/", "\\")


def _remote_parts(abs_path):
    """远端路径 → (共享名, 共享内相对路径)。`D:\\x\\y` → ('D$', 'x\\y')。"""
    p = str(abs_path or "").replace("/", "\\")
    if len(p) >= 2 and p[1] == ":":
        return p[0].upper() + "$", p[2:].lstrip("\\")
    return (CONFIG.get("smb_share") or "D$"), p.lstrip("\\")


def smb_backend():
    """读远端文件的后端：'unc'（Windows）或 'smbclient'（Linux）。"""
    m = str(CONFIG.get("smb_mode") or "auto").lower()
    if m in ("unc", "smbclient"):
        return m
    return "unc" if IS_WINDOWS else "smbclient"


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


def _read_unc(ip, unc):
    """读一个 UNC 文本文件。首次失败时 `net use` 预鉴权后重试一次；仍失败抛异常。"""
    err = None
    for attempt in (0, 1):
        try:
            with open(unc, "r", encoding="utf-8-sig", errors="replace") as f:
                return f.read()
        except Exception as e:
            err = e
            if attempt == 0 and ip not in _SMB_DONE and _smb_preauth(ip):
                _SMB_DONE.add(ip)
                continue
            break
    raise err


# ---------- Linux：smbclient 后端 ----------
def _smbclient_cmd(ip, share, script):
    """组装一条 smbclient 调用。密码走 PASSWD 环境变量，不落 argv（避免 ps 泄露）。"""
    exe = shutil.which(str(CONFIG.get("smbclient_exe") or "smbclient")) or "smbclient"
    t = str(int(CONFIG.get("smb_timeout") or 25))
    return ([exe, "//%s/%s" % (ip, share), "-U", str(CONFIG.get("rdp_user") or "a"),
             "-t", t, "-c", script],
            dict(os.environ, PASSWD=str(CONFIG.get("rdp_password") or "a")))


def _smbclient_run(ip, share, script):
    cmd, env = _smbclient_cmd(ip, share, script)
    to = int(CONFIG.get("smb_timeout") or 25) + 10
    try:
        out = subprocess.run(cmd, capture_output=True, timeout=to, env=env)
    except FileNotFoundError:
        raise RuntimeError("未找到 smbclient（Linux 请 `apt install smbclient`，或改用挂载）")
    except subprocess.TimeoutExpired:
        raise RuntimeError("smbclient 超时（%ss）" % to)
    if out.returncode != 0:
        msg = (out.stderr or out.stdout).decode("utf-8", "replace").strip()
        raise RuntimeError(msg.splitlines()[-1][:200] if msg else "smbclient 返回 %d" % out.returncode)
    return out.stdout


def _smbclient_read(ip, share, rel):
    fd, tmp = tempfile.mkstemp(prefix="wb-smb-")
    os.close(fd)
    try:
        _smbclient_run(ip, share, 'get "%s" "%s"' % (rel.replace("\\", "/"), tmp.replace("\\", "/")))
        with open(tmp, "r", encoding="utf-8-sig", errors="replace") as f:
            return f.read()
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _smbclient_write(ip, share, rel, text):
    fd, tmp = tempfile.mkstemp(prefix="wb-smb-", suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        _smbclient_run(ip, share, 'put "%s" "%s"' % (tmp.replace("\\", "/"), rel.replace("\\", "/")))
        return True
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _smbclient_list(ip, share, rel):
    out = _smbclient_run(ip, share, 'ls "%s"' % (rel.replace("\\", "/")))
    names = []
    for line in out.decode("utf-8", "replace").splitlines():
        s = line.strip()
        if not s:
            continue
        name = s.split()[0]
        if name in (".", ".."):
            continue
        names.append(name)
    return names


# ---------- 统一入口 ----------
def read_remote_text(ip, rel):
    """读远端机器上 D:\\cloudrdp-sys 下的文本文件。失败抛异常。"""
    return read_remote_abs(ip, _rel_to_abs(rel))


def read_remote_abs(ip, abs_path):
    """读远端机器上任意绝对路径的文本文件（如 runner 工作区）。失败抛异常。"""
    if smb_backend() == "smbclient":
        share, rel = _remote_parts(abs_path)
        return _smbclient_read(ip, share, rel)
    return _read_unc(ip, _unc_abs(ip, abs_path))


def write_remote_text(ip, rel, text):
    """把文本写到远端机器 D:\\cloudrdp-sys 下的相对路径（用于下发备份请求）。"""
    abs_path = _rel_to_abs(rel)
    share, sub = _remote_parts(abs_path)
    if smb_backend() == "smbclient":
        return _smbclient_write(ip, share, sub, text)
    unc = _unc_abs(ip, abs_path)
    try:
        with open(unc, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        return True
    except Exception:
        if ip not in _SMB_DONE and _smb_preauth(ip):
            _SMB_DONE.add(ip)
            with open(unc, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            return True
        raise


def list_remote_dir(ip, abs_path):
    """列远端某目录下的条目名（best-effort）。失败抛异常。"""
    if smb_backend() == "smbclient":
        share, rel = _remote_parts(abs_path)
        return _smbclient_list(ip, share, rel)
    return os.listdir(_unc_abs(ip, abs_path))


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


def parse_git_origin_owner(text):
    """从 runner 工作区 `.git/config` 文本里取 origin 的 GitHub owner；取不到返回 ""。

    Actions 的 checkout 有时把 URL 写成 `https://x-access-token:<token>@github.com/o/r`，
    **只提取 owner，绝不返回/记录整条 url**，避免把 token 带出去。
    """
    m = re.search(r"url\s*=\s*(\S+)", text or "")
    if not m:
        return ""
    mm = re.search(r"github\.com[:/]+([^/\s]+)/", m.group(1))
    return mm.group(1) if mm else ""


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


def parse_snapshot_manifest(man):
    """从 `_snapshot/manifest.json` 提取前端需要的字段（兼容新旧两种格式）。

    现行 manifest（backup-snapshot.ps1 写的）用的是：
      createdUtc / createdLocal（ISO，7 位小数秒）、
      files = { totalFiles, totalBytes, entries, skipped }、mode、status。
    老格式是扁平的 file_count / created_utc。两种都认。
    """
    if not isinstance(man, dict):
        return None
    fb = man.get("files")
    files = bytes_ = None
    if isinstance(fb, dict):
        files = fb.get("totalFiles", fb.get("total_files"))
        bytes_ = fb.get("totalBytes", fb.get("total_bytes"))
    if files is None:
        files = man.get("file_count") or man.get("count")
    if bytes_ is None:
        bytes_ = man.get("total_bytes") or man.get("bytes")
    when = (man.get("createdUtc") or man.get("created_utc") or man.get("createdLocal")
            or man.get("created_local") or man.get("created") or man.get("time")
            or man.get("updated_utc"))
    age_min, local_str = None, ""
    dt = parse_iso(when)
    if dt:
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        age_min = (datetime.now(timezone.utc) - dt).total_seconds() / 60.0
        local_str = dt.astimezone().strftime("%m-%d %H:%M")   # 本机时区的绝对时间
    return {
        "ok": True,
        "created": when,
        "created_local": local_str,
        "age_human": human_age(when),
        "age_minutes": age_min,
        "files": files,
        "bytes": bytes_,
        "mode": man.get("mode") or "",
        "status": man.get("status") or "",
        "stale": (age_min is not None and age_min > float(CONFIG.get("snapshot_stale_minutes") or 90)),
    }


def machine_detail(ip, online):
    """读单台机器的池角色 + 快照新鲜度 + 运行时长 + 归属账号。任何一项读不到就留空，不抛。"""
    detail = {"role": "", "role_source": "", "snapshot": None, "error": "",
              "started_utc": "", "uptime_seconds": None, "uptime_human": "",
              "pool_owner": "", "pool_id": "", "assigned_role": "", "owner_source": "",
              "restore": {"data": {}, "snapshot": {}, "source": ""}}
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
        man = json.loads(read_remote_text(ip, "_snapshot/manifest.json"))
        detail["snapshot"] = parse_snapshot_manifest(man) or {"ok": False}
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
    # 归属账号（来源 ①）：池模式机器写的 _state\pool-info.txt 里的 pool_owner
    try:
        info = parse_pool_info(read_remote_text(ip, "_state/pool-info.txt"))
        detail["pool_owner"] = info.get("pool_owner", "")
        detail["pool_id"] = info.get("pool_id", "")
        detail["assigned_role"] = info.get("assigned_role", "")
        if detail["pool_owner"]:
            detail["owner_source"] = "_state/pool-info.txt"
    except Exception:
        pass
    # 归属账号（来源 ②，兜底）：单机/老机器没有 pool-info.txt，
    #   但 runner 工作区 D:\a\<repo>\<repo>\.git\config 的 origin owner 就是账号。
    if not detail["pool_owner"]:
        repo_name = (str(CONFIG.get("repo") or "").split("/")[-1] or "cloud-rdp")
        cands = [r"D:\a\%s\%s\.git\config" % (repo_name, repo_name)]
        try:   # 兜底再兜底：扫 D:\a 下第一个非 _ 目录（仓库名变了也能兜住）
            for name in sorted(list_remote_dir(ip, r"D:\a")):
                if not name.startswith("_"):
                    cands.append(r"D:\a\%s\%s\.git\config" % (name, name))
        except Exception:
            pass
        for abs_path in cands:
            try:
                owner = parse_git_origin_owner(read_remote_abs(ip, abs_path))
            except Exception:
                owner = ""
            if owner:
                detail["pool_owner"] = owner
                detail["owner_source"] = "runner 工作区 .git/config"
                break
    # 一键备份：机器上是否还挂着未处理的备份请求（保活循环取走后会删掉）
    detail["backup_request"] = read_backup_request(ip)
    # 数据/快照恢复状态（acc-1 事故后新增：让「没拉取到数据」一眼可见）
    detail["restore"] = read_restore_status(ip)
    return detail


def read_backup_request(ip):
    """读机器上的 `_state/backup-request.txt`（一键备份请求）。无请求返回 pending=False。

    文件由工作台经 SMB 写入，机器的保活循环每分钟轮询一次、取走后立即删除。
    所以「pending=True」= 请求已下发、机器还没处理。
    """
    out = {"pending": False, "requested_at": "", "requested_by": ""}
    try:
        info = parse_pool_info(read_remote_text(ip, CONFIG.get("backup_request_file")
                                               or "_state/backup-request.txt"))
        if info:
            out["pending"] = True
            out["requested_at"] = info.get("requested_at", "")
            out["requested_by"] = info.get("requested_by", "")
    except Exception:
        pass
    return out


def read_restore_status(ip):
    """读机器上的 `_state/restore-status.json`（数据/快照恢复状态）。

    结构（由脚本侧的 remote-lib.ps1 Set-RestoreStatus 写入，按作用域合并）：
        { "data": {"status","reason","at_utc"}, "snapshot": {...} }
    兼容旧的扁平结构 `{status,reason}`。再读不到就回退到旧标记文件
    （`<数据目录>\\_RESTORE_FAILED.txt` / `_RESTORE_EMPTY.txt`）。

    返回 {"data": {...}, "snapshot": {...}, "source": "..."}；任何异常都不抛。
    """
    out = {"data": {}, "snapshot": {}, "source": ""}

    def _norm(v):
        if not isinstance(v, dict):
            return {}
        return {"status": str(v.get("status") or "").upper(),
                "reason": str(v.get("reason") or ""),
                "at_utc": str(v.get("at_utc") or "")}

    try:
        raw = read_remote_text(ip, "_state/restore-status.json")
        if raw and raw.strip():
            o = json.loads(raw)
            if isinstance(o, dict):
                out["data"] = _norm(o.get("data"))
                out["snapshot"] = _norm(o.get("snapshot"))
                if not out["data"] and o.get("status"):
                    out["data"] = _norm(o)      # 旧扁平结构
                if out["data"] or out["snapshot"]:
                    out["source"] = "_state/restore-status.json"
                    return out
    except Exception:
        pass

    # 回退：旧标记文件（老机器/老脚本留下的）
    data_dir = str(CONFIG.get("data_dir") or r"D:\a\cloud-rdp").rstrip("\\/")
    for fname, st in (("_RESTORE_FAILED.txt", "FAILED"), ("_RESTORE_EMPTY.txt", "EMPTY")):
        try:
            read_remote_abs(ip, data_dir + "\\" + fname)
            out["data"] = {"status": st, "reason": "（旧标记文件 %s）" % fname, "at_utc": ""}
            out["source"] = "标记文件"
            break
        except Exception:
            continue
    return out


# 恢复状态 → 展示类别（前端与统计共用一套口径，避免两边判色不一致）
RESTORE_OK = ("OK", "PARTIAL")
RESTORE_EMPTY = ("EMPTY", "SKIPPED")
RESTORE_BAD = ("TRANSIENT", "FAILED", "AUTH", "PENDING")


def restore_kind(status):
    """把恢复状态字符串归成 ok / empty / bad / none 四类。"""
    s = str(status or "").upper()
    if s in RESTORE_OK:
        return "ok"
    if s in RESTORE_EMPTY:
        return "empty"
    if s in RESTORE_BAD:
        return "bad"
    return "none"


def machine_restore_summary(m):
    """从一台机器的 restore 字段里取最该被关注的那条状态（bad 优先于 ok）。"""
    r = (m or {}).get("restore") or {}
    picks = []
    for scope in ("data", "snapshot"):
        st = str((r.get(scope) or {}).get("status") or "")
        if st:
            picks.append((scope, st))
    if not picks:
        return {"kind": "none", "scope": "", "status": ""}
    # 任一作用域 bad → bad；否则任一 empty → empty；否则 ok
    for scope, st in picks:
        if restore_kind(st) == "bad":
            return {"kind": "bad", "scope": scope, "status": st}
    for scope, st in picks:
        if restore_kind(st) == "empty":
            return {"kind": "empty", "scope": scope, "status": st}
    scope, st = picks[0]
    return {"kind": "ok", "scope": scope, "status": st}


def request_backup(ip, requested_by=""):
    """下发「一键备份」：把请求文件写到机器上，保活循环取走后执行 sync-up + 快照推送。

    为什么走文件而不是直接触发：机器是 GitHub Actions runner，没有对外命令通道；
    但保活循环每分钟跑一次，写个请求文件让它自己捡走是最省事、也最稳的做法。
    （需要机器跑的是支持该轮询的 workflow —— 见 .github/workflows/windows-rdp.yml 第 14 步。）
    """
    ip = (ip or "").strip()
    if not ip:
        return {"ok": False, "error": "缺少 ip"}
    if not re.match(r"^[0-9A-Za-z_.\-]+$", ip):
        return {"ok": False, "error": "IP 非法：%s" % ip}
    rel = CONFIG.get("backup_request_file") or "_state/backup-request.txt"
    body = ("requested_at=%s\nrequested_by=%s\nreason=manual\n"
            % (now_iso(), requested_by or "workbench"))
    try:
        write_remote_text(ip, rel, body)
    except Exception as e:
        return {"ok": False, "error": "写备份请求失败：%s" % e, "file": rel}
    return {"ok": True, "error": "", "file": rel, "ip": ip,
            "note": "已下发备份请求：机器会在 ≤1 分钟内执行「同步数据到 139 + 快速快照推送」"}


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
        "created_beijing": beijing_time(r.get("created_at") or ""),
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
    prov_owners = _provisioning_owners()
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
            # 正在自动部署中（后台任务 status=running）—— 前端据此显示「部署中…」，
            # 避免刚添加、Secret 还没写完时被误报成红色的「缺失」
            "provisioning": owner in prov_owners,
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
            "state_updated_beijing": beijing_time(state.get("updated_utc") or ""),
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
        "created_beijing": beijing_time(created),
        "updated_at": updated,
        "updated_human": human_age(updated),
        "updated_beijing": beijing_time(updated),
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
def default_rdp_dir():
    """一键登录 .rdp 的默认落地目录：~/Documents/CloudRDP（不再写桌面）。"""
    return os.path.join(os.path.expanduser("~"), "Documents", "CloudRDP")


def rdp_dir():
    """一键登录 .rdp 的落地目录。

    留空 = 用默认目录（~/Documents/CloudRDP），**绝不回落到桌面**；
    目录不存在会自动创建；实在建不出来才退到系统临时目录兜底。
    """
    d = _expand(CONFIG.get("rdp_dir") or "") or default_rdp_dir()
    try:
        os.makedirs(d, exist_ok=True)
    except OSError as e:
        sys.stderr.write("[warn] 建 .rdp 目录失败 %s: %s，改用临时目录\n" % (d, e))
        d = tempfile.gettempdir()
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


def default_rdp_path():
    """mstsc 的「默认连接设置」文件（`mstsc /v:` 会以它为模板）。"""
    return os.path.join(os.path.expanduser("~"), "Documents", "Default.rdp")


def default_rdp_status():
    """Default.rdp 现状：路径 / 是否存在 / authentication level / 是否已备份。"""
    p = default_rdp_path()
    exists = os.path.isfile(p)
    level = None
    if exists:
        try:
            with open(p, "r", encoding="ascii", errors="replace") as f:
                m = re.search(r"authentication level:i:(\d+)", f.read())
            level = int(m.group(1)) if m else None
        except Exception:
            level = None
    return {"path": p, "exists": exists, "auth_level": level,
            "auth_zero": level == 0, "backup": os.path.isfile(p + ".bak-workbench")}


def ensure_default_rdp_auth_level():
    """确保 Default.rdp 里 `authentication level:i:0`（连自签证书机器不再弹「无法验证身份」）。

    `mstsc /v:<ip>` 会读取 Default.rdp 作为模板；把认证级别设为 0 后，证书警告也消失，
    于是「手动连接」路径可以做到**零弹窗**。首次改动前会把原文件备份为
    `Default.rdp.bak-workbench`（只备份一次）。返回 (ok, 说明文字)。
    """
    if not IS_WINDOWS:
        return (False, "非 Windows")
    p = default_rdp_path()
    if not os.path.isfile(p):
        try:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="ascii", newline="") as f:
                f.write("screen mode id:i:2\r\nauthentication level:i:0\r\n"
                        "prompt for credentials:i:0\r\n")
            return (True, "已新建 Default.rdp（authentication level=0）")
        except Exception as e:
            return (False, "新建 Default.rdp 失败：%s" % e)
    try:
        with open(p, "r", encoding="ascii", errors="replace") as f:
            txt = f.read()
    except Exception as e:
        return (False, "读 Default.rdp 失败：%s" % e)
    if re.search(r"authentication level:i:0\b", txt):
        return (True, "Default.rdp 已是 authentication level=0")
    bak = p + ".bak-workbench"
    if not os.path.isfile(bak):
        try:
            shutil.copy2(p, bak)
        except Exception:
            pass
    if re.search(r"authentication level:i:\d+", txt):
        txt = re.sub(r"authentication level:i:\d+", "authentication level:i:0", txt)
    else:
        txt = txt.rstrip("\r\n") + "\r\nauthentication level:i:0\r\n"
    try:
        with open(p, "w", encoding="ascii", newline="") as f:
            f.write(txt)
        return (True, "已把 Default.rdp 的 authentication level 改为 0（原文件备份为 "
                      "Default.rdp.bak-workbench）")
    except Exception as e:
        return (False, "写 Default.rdp 失败：%s" % e)


def _launch_rdp_linux(ip, rdp_path, mode):
    """Linux：按配置的客户端命令唤起（xfreerdp / remmina 等）。"""
    tmpl = str(CONFIG.get("rdp_client_cmd") or "").strip()
    if not tmpl:   # 自动探测常见客户端
        for exe, t in (("xfreerdp", "xfreerdp /v:{ip} /u:{user} /p:{password} /cert:ignore /dynamic-resolution"),
                       ("xfreerdp3", "xfreerdp3 /v:{ip} /u:{user} /p:{password} /cert:ignore /dynamic-resolution"),
                       ("remmina", "remmina -c {file}")):
            if shutil.which(exe):
                tmpl = t
                break
    if not tmpl:
        return (False, "未找到 RDP 客户端：配置 rdp_client_cmd，或安装 xfreerdp / remmina",
                mode, "已生成 .rdp 文件，可手动导入客户端")
    cmd = (tmpl.replace("{ip}", ip).replace("{user}", str(CONFIG.get("rdp_user") or "a"))
              .replace("{password}", str(CONFIG.get("rdp_password") or "a"))
              .replace("{file}", rdp_path))
    try:
        subprocess.Popen(shlex.split(cmd))
        return (True, "", mode, "已用 Linux RDP 客户端唤起：%s" % cmd.split()[0])
    except Exception as e:
        return (False, "唤起失败：%s" % e, mode, "")


def launch_rdp(ip, rdp_path):
    """唤起远程桌面连接。返回 (launched, error, mode, note)。

    默认走 `mstsc /v:<ip>`：2026-04 KB5083769（CVE-2026-26151）之后，
    **只有打开 .rdp 文件**才会弹「远程桌面连接安全警告 / 资源勾选」阻断框，
    手动连接（命令行 /v:）不受影响；再把 Default.rdp 认证级别置 0，证书警告也没了。
    Linux 上走 `rdp_client_cmd` / 自动探测 xfreerdp。
    """
    mode = str(CONFIG.get("rdp_launch_mode") or "mstsc").lower()
    if not IS_WINDOWS:
        return _launch_rdp_linux(ip, rdp_path, mode)
    if mode == "file":
        try:
            os.startfile(rdp_path)  # noqa: S606
            return (True, "", mode, "")
        except Exception as e:
            return (False, "唤起失败：%s" % e, mode, "")
    # mstsc /v:<ip>
    _ok, note = ensure_default_rdp_auth_level()
    try:
        subprocess.Popen(["mstsc", "/v:" + ip])
        return (True, "", mode, note)
    except Exception as e:
        return (False, "唤起失败：%s" % e, mode, note)


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
    launch_mode = str(CONFIG.get("rdp_launch_mode") or "mstsc").lower()
    launch_note = ""
    if launch:
        launched, launch_error, launch_mode, launch_note = launch_rdp(ip, path)
    return {"ok": True, "path": path, "ip": ip, "user": user,
            "cred_stored": cred.get("ok"), "cred_error": cred.get("error") or "",
            "launched": launched, "launch_error": launch_error,
            "launch_mode": launch_mode, "launch_note": launch_note}


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

    # 数据/快照恢复：把「没拉取到数据」计入统计，让概览页一眼可见（acc-1 事故后新增）
    def _scope_bad(scope):
        n = 0
        for m in machines:
            st = str(((m.get("restore") or {}).get(scope) or {}).get("status") or "")
            if restore_kind(st) == "bad":
                n += 1
        return n

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
            "machines_data_bad": _scope_bad("data"),
            "machines_snapshot_bad": _scope_bad("snapshot"),
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
        ck = getattr(self, "_set_cookie", "")
        if ck:
            self.send_header("Set-Cookie", ck)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _auth_ok(self, params):
        """访问控制：配置了 access_token 就要求带 token（?token= / X-Workbench-Token / Cookie）。"""
        want = str(CONFIG.get("access_token") or "")
        if not want:
            return True
        given = (params.get("token") or [""])[0] or (self.headers.get("X-Workbench-Token") or "")
        if not given:
            m = re.search(r"(?:^|;\s*)wb_token=([^;]+)", self.headers.get("Cookie") or "")
            if m:
                given = urllib.parse.unquote(m.group(1))
        if given != want:
            return False
        if params.get("token"):   # 用 ?token= 进来 → 种个 Cookie，后续请求免带
            self._set_cookie = "wb_token=%s; Path=/; HttpOnly; SameSite=Lax" % urllib.parse.quote(given)
        return True

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
            if not self._auth_ok(params):
                if path.startswith("/api/"):
                    return self._json(401, {"ok": False, "error":
                                            "未授权：请用 ?token=<access_token> 打开，或带 X-Workbench-Token 头"})
                return self._send(401, (
                    "<!doctype html><meta charset=utf-8><title>401 需要访问令牌</title>"
                    "<div style='font:15px/1.7 system-ui;max-width:640px;margin:12vh auto;padding:0 20px'>"
                    "<h2>需要访问令牌</h2><p>这个工作台配置了 <code>access_token</code>，"
                    "请在地址后加 <code>?token=你的令牌</code> 再打开一次（之后会记住）。</p>"
                    "<p>例：<code>http://&lt;服务器&gt;:8899/?token=xxxx</code></p></div>"),
                    "text/html; charset=utf-8")
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


# ================================================= 账号自动部署（provision，一键）
# 目标：在「GitHub 账号管理」里新增账号后，自动把这个账号的仓库部署好、
#       并接入账号池（协调器随后会自动补机 / 主挂备顶），让机器不间断。
#
# 三个绕不开的事实（决定了实现方式）：
#   ① GitHub 的 Actions Secret **只能写、永远读不回** → 无法「复制」hub 的机器密钥。
#      唯一可行办法：在 hub 里跑一个**临时 workflow**，它用 `${{ secrets.X }}` 取到值，
#      再用目标账号的 PAT 执行 `gh secret set --repo <fork>` 写进 fork。
#      （本仓库 .tmp-lint/sync-secrets.py 已验证过这条链路。）
#   ② 因此部署新账号**必须**拿到该账号自己的 PAT：建 fork / 开 Actions / 写 Secret 都要它。
#   ③ PAT 只落在本机 .tools/pool/<owner>.token，**绝不**进 pool-config.json、绝不进 git。
#
# 整个流程要跑几分钟（等临时 workflow），所以走**后台任务 + 轮询**，不阻塞 HTTP。

_PROVISION_JOBS = {}
_PROVISION_LOCK = threading.Lock()


def _provisioning_owners():
    """正在自动部署中（status=running）的 owner 集合。"""
    with _PROVISION_LOCK:
        return set(str(j.get("owner") or "") for j in _PROVISION_JOBS.values()
                   if j.get("status") == "running")

# 需要从 hub 复制到新 fork 的机器密钥（hub 里没有的会自动跳过）
_SYNC_SECRETS = [
    "TAILSCALE_AUTHKEY", "ALIST_139_AUTHORIZATION", "GH_RELAY_TOKEN", "GH_BILLING_TOKEN",
    "MAIL_SMTP_HOST", "MAIL_SMTP_PORT", "MAIL_SECURITY", "MAIL_USER", "MAIL_PASS",
    "MAIL_FROM", "MAIL_FROM_NAME", "MAIL_TO", "MAIL_CC",
]


class _ProvStop(Exception):
    """provision 流程遇到「必须中止」的错误（后续步骤无意义）。"""


def pool_token_dir():
    """本机账号 PAT 存放目录（与 hub token 同级，都在 .tools/ 下，不进 git）。"""
    return os.path.abspath(os.path.join(REPO_ROOT, "..", ".tools", "pool"))


def save_account_token(owner, token):
    d = pool_token_dir()
    try:
        os.makedirs(d, exist_ok=True)
    except Exception:
        pass
    p = os.path.join(d, "%s.token" % owner)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(str(token).strip() + "\n")
    try:
        os.chmod(p, 0o600)
    except Exception:
        pass
    return p


def load_account_token(owner):
    p = os.path.join(pool_token_dir(), "%s.token" % owner)
    if os.path.isfile(p):
        try:
            return open(p, encoding="utf-8-sig").read().strip() or None
        except Exception:
            return None
    return None


def gh_api_as(token, path, method="GET", body=None, params=None, timeout=None):
    """用「指定 token」（而非本机 hub token）调 GitHub API。"""
    if OFFLINE:
        return {}
    url = "https://api.github.com" + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    headers = {"Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28",
               "Authorization": "Bearer " + str(token)}
    return http_json(url, method=method, headers=headers, body=body, timeout=timeout)


def _http_err_body(e):
    try:
        return e.read().decode("utf-8", "replace")[:300]
    except Exception:
        return ""


def gh_cli_path():
    gh = shutil.which("gh") or shutil.which("gh.exe")
    if gh:
        return gh
    for cand in (os.path.join(REPO_ROOT, "..", ".tools", "bin", "gh.exe"),
                 os.path.join(REPO_ROOT, ".tools", "bin", "gh.exe")):
        if os.path.isfile(cand):
            return os.path.abspath(cand)
    return None


def gh_secret_set(repo, name, value, token=None):
    """用本机 gh CLI 写仓库 Secret（值只能写不能读）。返回 (ok, detail)。"""
    gh = gh_cli_path()
    if not gh:
        return False, "本机找不到 gh CLI，无法写 Secret（可手动到仓库 Settings→Secrets 添加）"
    env = dict(os.environ)
    tk = token or resolve_token()
    if tk:
        env["GH_TOKEN"] = tk
    try:
        out = subprocess.run([gh, "secret", "set", name, "--repo", repo, "--body", value],
                             capture_output=True, timeout=90, env=env, creationflags=NO_WINDOW)
    except Exception as e:
        return False, "%s: %s" % (type(e).__name__, e)
    if out.returncode == 0:
        return True, "已写入 Secret %s" % name
    msg = (out.stderr or out.stdout or b"").decode("utf-8", "replace").strip()
    return False, (msg[:300] or "gh 返回非零（%s）" % out.returncode)


def verify_token_owner(token):
    """校验 PAT 有效并返回其登录名（无效则抛异常）。"""
    d = gh_api_as(token, "/user", timeout=15)
    return str((d or {}).get("login") or "")


def ensure_fork(owner, repo, token):
    """确保 owner/repo 存在；不存在则把 hub fork 到 owner 名下。
    返回 (state, detail, note)：state ∈ {'exists','forked','error'}。"""
    hub = CONFIG.get("repo") or ""
    try:
        gh_api_as(token, "/repos/%s/%s" % (owner, repo), timeout=20)
        return "exists", "仓库已存在（跳过 fork）", ""
    except urllib.error.HTTPError as e:
        if e.code != 404:
            return "error", "查询仓库失败：HTTP %s %s" % (e.code, _http_err_body(e)), ""
    except Exception as e:
        return "error", "查询仓库异常：%s: %s" % (type(e).__name__, e), ""

    # 404 → 用该账号的 PAT 建 fork（fork 会落到 token 主人名下 = 新账号）
    try:
        gh_api_as(token, "/repos/%s/forks" % hub, method="POST", body={}, timeout=60)
    except urllib.error.HTTPError as e:
        return "error", "创建 fork 失败：HTTP %s %s" % (e.code, _http_err_body(e)), ""
    except Exception as e:
        return "error", "创建 fork 异常：%s: %s" % (type(e).__name__, e), ""

    for _ in range(12):          # fork 是异步的，最多等 60s
        time.sleep(5)
        try:
            gh_api_as(token, "/repos/%s/%s" % (owner, repo), timeout=20)
            return "forked", "已从 %s fork 出 %s/%s" % (hub, owner, repo), ""
        except Exception:
            continue
    return "forked", "已发起 fork，仓库仍在生成中", "fork 尚未就绪：可稍后在界面重跑一次部署"


def enable_actions(owner, repo, token):
    """在 fork 里开启 Actions（fork 默认是关的）+ 允许所有 action + 启用各 workflow。"""
    notes = []
    try:
        gh_api_as(token, "/repos/%s/%s/actions/permissions" % (owner, repo), method="PUT",
                  body={"enabled": True, "allowed_actions": "all"}, timeout=25)
        notes.append("Actions 已启用")
    except urllib.error.HTTPError as e:
        return False, "开启 Actions 失败：HTTP %s %s" % (e.code, _http_err_body(e))
    except Exception as e:
        return False, "开启 Actions 异常：%s: %s" % (type(e).__name__, e)

    for wf in sorted(set((CONFIG.get("workflows") or {}).values())):
        try:
            gh_api_as(token, "/repos/%s/%s/actions/workflows/%s/enable" % (owner, repo, wf),
                      method="PUT", timeout=25)
            notes.append("启用 %s" % wf)
        except Exception:
            notes.append("启用 %s 跳过（可能不存在）" % wf)
    return True, "；".join(notes)


def _sync_wf_yaml(target_full, secret_name):
    """生成一次性「把 hub 密钥写进 fork」的临时 workflow。"""
    lines = [
        "name: _tmp sync secrets (auto, one-shot)",
        "on:",
        "  workflow_dispatch:",
        "permissions: {}",
        "jobs:",
        "  sync:",
        "    runs-on: ubuntu-latest",
        "    steps:",
        "      - name: copy hub secrets to %s" % target_full,
        "        env:",
        "          GH_TOKEN: ${{ secrets.%s }}" % secret_name,
        "          TARGET: %s" % target_full,
    ]
    for s in _SYNC_SECRETS:
        lines.append("          S_%s: ${{ secrets.%s }}" % (s, s))
    run = [
        "set -euo pipefail",
        "gh --version | head -1",
        'set_one() { name="$1"; val="$2"; if [ -z "$val" ]; then echo "skip $name (empty)"; '
        'return 0; fi; gh secret set "$name" --repo "$TARGET" --body "$val" >/dev/null '
        '&& echo "set $name -> ok"; }',
    ]
    for s in _SYNC_SECRETS:
        run.append('set_one %s "$S_%s"' % (s, s))
    run.append('echo "--- target secret names ---"')
    run.append('gh secret list --repo "$TARGET"')
    lines.append("        run: |")
    for r in run:
        lines.append("          " + r)
    return "\n".join(lines) + "\n"


def sync_secrets_to_fork(owner, repo, secret_name):
    """在 hub 跑临时 workflow，把 hub 的机器密钥写进 owner/repo（fork）。返回 (ok, detail)。"""
    hub = CONFIG.get("repo") or ""
    ref = CONFIG.get("ref") or "main"
    path = ".github/workflows/_tmp-sync-secrets.yml"
    yml = _sync_wf_yaml("%s/%s" % (owner, repo), secret_name)
    content = base64.b64encode(yml.encode("utf-8")).decode()

    # 1) 建/更新临时 workflow
    sha = None
    try:
        d = gh_api("/repos/%s/contents/%s" % (hub, path), params={"ref": ref}, timeout=30)
        sha = d.get("sha")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            return False, "读取临时 workflow 失败：HTTP %s" % e.code
    body = {"message": "chore(tmp): 一次性 Secret 同步（跑完自动删除）",
            "content": content, "branch": ref}
    if sha:
        body["sha"] = sha
    try:
        gh_api("/repos/%s/contents/%s" % (hub, path), method="PUT", body=body, timeout=60)
    except urllib.error.HTTPError as e:
        return False, "创建临时 workflow 失败：HTTP %s %s" % (e.code, _http_err_body(e))

    # 2) 派发（文件刚建，稍等 + 重试）
    dispatched = False
    for _ in range(10):
        time.sleep(4)
        try:
            gh_api("/repos/%s/actions/workflows/%s/dispatches" % (hub, "_tmp-sync-secrets.yml"),
                   method="POST", body={"ref": ref}, timeout=30)
            dispatched = True
            break
        except urllib.error.HTTPError as e:
            if e.code in (404, 422):
                continue
            return False, "派发临时 workflow 失败：HTTP %s" % e.code
        except Exception:
            continue
    if not dispatched:
        return False, "派发临时 workflow 失败（重试 10 次仍未成功）"

    # 3) 等 run 完成（最多 ~3 分钟）
    ok, detail = False, "临时 workflow 未在 3 分钟内完成（可稍后在 Actions 里查看）"
    for _ in range(36):
        time.sleep(5)
        try:
            d = gh_api("/repos/%s/actions/workflows/%s/runs" % (hub, "_tmp-sync-secrets.yml"),
                       params={"per_page": 1}, timeout=20)
        except Exception:
            continue
        runs = (d or {}).get("workflow_runs") or []
        if not runs:
            continue
        r0 = runs[0]
        if r0.get("status") == "completed":
            cc = r0.get("conclusion")
            ok = (cc == "success")
            detail = "机器密钥同步 %s（run #%s）" % (
                "成功" if ok else "失败：%s" % cc, r0.get("run_number") or r0.get("id"))
            break

    # 4) 删除临时 workflow（无论成败，避免留在仓库里）
    try:
        d = gh_api("/repos/%s/contents/%s" % (hub, path), params={"ref": ref}, timeout=30)
        gh_api("/repos/%s/contents/%s" % (hub, path), method="DELETE", timeout=30,
               body={"message": "chore(tmp): 删除一次性 Secret 同步 workflow",
                     "sha": d.get("sha"), "branch": ref})
    except Exception:
        pass
    return ok, detail


def push_pool_config_to_hub(local_cfg):
    """把账号清单合并进 hub 仓库的 pool-config.json 并提交（协调器读的是 hub 上的这份）。
    返回 (ok, detail)。"""
    hub = CONFIG.get("repo") or ""
    rel = CONFIG.get("pool_config") or "scripts/pool-config.json"
    ref = CONFIG.get("ref") or "main"
    sha, hub_cfg = None, {}
    try:
        d = gh_api("/repos/%s/contents/%s" % (hub, rel), params={"ref": ref}, timeout=30)
        sha = d.get("sha")
        try:
            hub_cfg = json.loads(base64.b64decode(d.get("content") or "").decode("utf-8"))
        except Exception:
            hub_cfg = {}
    except urllib.error.HTTPError as e:
        if e.code != 404:
            return False, "读取 hub 配置失败：HTTP %s" % e.code
    except Exception as e:
        return False, "读取 hub 配置异常：%s: %s" % (type(e).__name__, e)

    # 合并：非 accounts 字段以本地为准；accounts 以 owner 为键并集（本地覆盖 hub）
    merged = dict(hub_cfg or {})
    for k, v in (local_cfg or {}).items():
        if k != "accounts":
            merged[k] = v
    by_owner = {}
    for a in (hub_cfg.get("accounts") or []) + (local_cfg.get("accounts") or []):
        if not isinstance(a, dict):
            continue
        o = str(a.get("owner") or "").lower()
        if o:
            by_owner[o] = a
    merged["accounts"] = list(by_owner.values())

    text = json.dumps(merged, ensure_ascii=False, indent=2) + "\n"
    body = {"message": "chore(pool): 新增/更新账号（工作台自动部署）",
            "content": base64.b64encode(text.encode("utf-8")).decode(), "branch": ref}
    if sha:
        body["sha"] = sha
    try:
        gh_api("/repos/%s/contents/%s" % (hub, rel), method="PUT", body=body, timeout=60)
    except urllib.error.HTTPError as e:
        return False, "提交 hub 配置失败：HTTP %s %s" % (e.code, _http_err_body(e))
    except Exception as e:
        return False, "提交 hub 配置异常：%s: %s" % (type(e).__name__, e)
    try:
        save_pool_config(merged)     # 本地同步成合并后的版本，避免两边漂移
    except Exception:
        pass
    return True, "已提交到 %s@%s" % (hub, ref)


def _prov_add(job, step, ok, detail="", note=""):
    job["steps"].append({"step": step, "ok": bool(ok), "detail": detail,
                         "note": note, "ts": now_iso()})


def _prov_run(job, owner, repo, secret_name, pat):
    """后台跑完整套远程部署步骤，逐步把结果追加到 job['steps']。"""
    hub = CONFIG.get("repo") or ""
    try:
        # 1) 校验 PAT 与 owner 是否匹配
        try:
            login = verify_token_owner(pat)
        except Exception as e:
            _prov_add(job, "verify_pat", False, "PAT 校验失败：%s: %s" % (type(e).__name__, e))
            raise _ProvStop()
        if not login:
            _prov_add(job, "verify_pat", False, "PAT 无效（/user 无返回）")
            raise _ProvStop()
        if login.lower() != owner.lower():
            _prov_add(job, "verify_pat", False,
                      "PAT 属于 %s，与 owner %s 不一致 —— 请填该账号自己的 PAT" % (login, owner))
            raise _ProvStop()
        _prov_add(job, "verify_pat", True, "PAT 有效：%s" % login)

        # 2) PAT 本地留存
        try:
            p = save_account_token(owner, pat)
            _prov_add(job, "save_pat", True, "PAT 已存本机（不进 git）：%s" % p)
        except Exception as e:
            _prov_add(job, "save_pat", False, "PAT 本地留存失败：%s" % e)

        # 3) 写 hub Secret（协调器要用它派发该账号）
        ok, detail = gh_secret_set(hub, secret_name, pat)
        _prov_add(job, "hub_secret", ok, detail)
        if not ok:
            raise _ProvStop()

        # 4) 确保 fork 存在
        try:
            state, detail, note = ensure_fork(owner, repo, pat)
            _prov_add(job, "fork", state != "error", detail, note)
            if state == "error":
                raise _ProvStop()
        except _ProvStop:
            raise
        except Exception as e:
            _prov_add(job, "fork", False, "建 fork 异常：%s: %s" % (type(e).__name__, e))
            raise _ProvStop()

        # 5) 开 Actions + 启用 workflow
        try:
            ok, detail = enable_actions(owner, repo, pat)
            _prov_add(job, "actions", ok, detail)
        except Exception as e:
            _prov_add(job, "actions", False, "%s: %s" % (type(e).__name__, e))

        # 6) 把 hub 机器密钥复制进 fork（临时 workflow）
        try:
            ok, detail = sync_secrets_to_fork(owner, repo, secret_name)
            _prov_add(job, "secrets_sync", ok, detail)
        except Exception as e:
            _prov_add(job, "secrets_sync", False, "%s: %s" % (type(e).__name__, e))

        # 7) 把 pool-config.json 推到 hub（协调器据此派发）
        pc = load_pool_config()
        if not pc["ok"]:
            _prov_add(job, "push_config", False, pc["error"])
            raise _ProvStop()
        ok, detail = push_pool_config_to_hub(pc["config"])
        _prov_add(job, "push_config", ok, detail)

        # 8) 触发协调器（随后它会自动补机 / 主挂备顶）
        res = dispatch_workflow("coordinator", {"dry_run": "false"})
        _prov_add(job, "dispatch", res.get("ok", False),
                  "已触发协调器巡检" if res.get("ok") else ("触发失败：%s" % res.get("error")))
        clear_cache()
        job["status"] = "done"
    except _ProvStop:
        job["status"] = "failed"
    except Exception as e:
        _prov_add(job, "error", False, "%s: %s" % (type(e).__name__, e))
        job["status"] = "failed"
    finally:
        job["finished_at"] = now_iso()
        if job["status"] == "running":
            job["status"] = "done"
        job["summary"] = _prov_summary(job)


def _prov_summary(job):
    steps = job.get("steps") or []
    bad = [s for s in steps if not s.get("ok")]
    if bad:
        return "有 %d 步失败：%s" % (len(bad), "、".join(s["step"] for s in bad))
    return "全部 %d 步成功，账号已入池" % len(steps)


def start_provision(owner, repo, secret_name, pat, config_step=None):
    """起一个后台部署任务，返回 job 字典（可立即返回给前端轮询）。"""
    job_id = "prov-%d-%s" % (int(time.time() * 1000), owner)
    job = {"id": job_id, "owner": owner, "repo": repo, "status": "running",
           "steps": [], "started_at": now_iso(), "finished_at": "", "summary": ""}
    if config_step:
        job["steps"].append(config_step)
    with _PROVISION_LOCK:
        _PROVISION_JOBS[job_id] = job
    threading.Thread(target=_prov_run, args=(job, owner, repo, secret_name, pat),
                     daemon=True).start()
    return job


def api_accounts_provision_status(h, params):
    jid = (params.get("id") or [""])[0]
    with _PROVISION_LOCK:
        job = _PROVISION_JOBS.get(jid)
    if not job:
        return h._json(404, {"ok": False, "error": "找不到部署任务 %s" % jid})
    snap = dict(job)
    snap["steps"] = list(job.get("steps") or [])
    h._json(200, {"ok": True, "job": snap})


def api_accounts_add(h, params):
    """新增账号：写回 pool-config.json（原子写）。PAT 绝不进本文件。

    必填只有 **PAT**（该账号的 Personal Access Token，需 repo + workflow 权限）——
    新账号往往连仓库都还没有，所以 Secret 名可留空，由本接口自动分配 `POOL_TOKEN_N`。
    若再带 auto_deploy（默认：给了 PAT 就开），则后台顺带「自动部署仓库 + 接入账号池」。"""
    body = h._read_body()
    owner = str(body.get("owner") or "").strip()
    repo = str(body.get("repo") or "cloud-rdp").strip()
    secret = str(body.get("token_secret") or "").strip()
    acc_id = str(body.get("id") or "").strip()
    pat = str(body.get("pat") or "").strip()
    auto_deploy = body.get("auto_deploy")
    if auto_deploy is None:
        auto_deploy = bool(pat)          # 默认：填了 PAT 就自动部署
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
    # 新账号（仓库可能还没建）只需要 PAT —— Secret 名可留空，自动分配
    if not pat:
        errs.append("PAT 必填（该账号的 Personal Access Token，需 repo + workflow 权限）")
    if secret and not _RE_SECRET.match(secret):
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

    # Secret 名留空 = 自动分配一个没被占用的 POOL_TOKEN_N（新账号常见：仓库还没建，
    # 谈不上已有 Secret，等自动部署时再由本工作台把 PAT 写进 hub 的这个名字）
    secret_auto = False
    if not secret:
        used = set(str(a.get("token_secret") or "") for a in accs)
        n = 1
        while ("POOL_TOKEN_%d" % n) in used:
            n += 1
        secret = "POOL_TOKEN_%d" % n
        secret_auto = True
    else:
        for a in accs:
            if str(a.get("token_secret") or "") == secret:
                return h._json(409, {"ok": False, "error": "Secret 名 %s 已被账号 %s 占用"
                                     % (secret, a.get("owner"))})

    # 仓库校验：明确 404 才拦；但若开了「自动部署」，404 正是要 fork 的场景 → 放行
    v_state, v_note = verify_repo_exists(owner, repo)
    if v_state == "missing":
        if auto_deploy and pat:
            v_note = "仓库尚不存在 —— 自动部署会从 hub fork 出来"
        else:
            return h._json(400, {"ok": False, "error": "%s（可勾选「自动部署」由 PAT 自动 fork）" % v_note})

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

    resp = {"ok": True, "id": acc_id, "account": entry, "path": pc["path"],
            "verified": v_state, "verify_note": v_note, "auto_deploy": False,
            "token_secret": secret, "secret_auto": secret_auto}

    if auto_deploy and pat:
        cfg_step = {"step": "config", "ok": True, "ts": now_iso(), "note": "",
                    "detail": "已写入 %s（id=%s%s）" % (os.path.basename(pc["path"]), acc_id,
                                                      "，Secret 名自动分配为 %s" % secret if secret_auto else "")}
        job = start_provision(owner, repo, secret, pat, config_step=cfg_step)
        resp["auto_deploy"] = True
        resp["job_id"] = job["id"]
        resp["steps"] = list(job["steps"])
        resp["hint"] = ("已开始自动部署：建 fork → 开 Actions → 复制机器密钥 → "
                        "写 hub Secret（%s）→ 推送配置 → 触发协调器。可在下方查看进度。" % secret)
    else:
        resp["hint"] = ("PAT 不会写进本文件。请到 GitHub 仓库 Secrets 配置其一："
                        "① 推荐 —— Secret 名 POOL_TOKENS，值是 JSON，加一项 \"%s\": \"ghp_...\"；"
                        "② 或建名为 %s 的 Secret，值就是该账号的 PAT。" % (owner, secret))
    return h._json(200, resp)


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
        "launch_mode": str(CONFIG.get("rdp_launch_mode") or "mstsc"),
        "default_rdp": default_rdp_status(),
    })


def api_rdp_default(h, params):
    """GET 查 / POST 修 Default.rdp 的 authentication level（让 mstsc /v: 零弹窗）。"""
    if h.command == "POST":
        ok, note = ensure_default_rdp_auth_level()
        st = default_rdp_status()
        st.update({"ok": ok, "note": note})
        return h._json(200 if ok else 500, st)
    st = default_rdp_status()
    st["ok"] = True
    return h._json(200, st)


def api_backup(h, params):
    """POST /api/backup {ip} —— 一键备份：下发请求文件，机器保活循环执行同步+快照。"""
    body = h._read_body()
    res = request_backup(body.get("ip") or "", requested_by=str(body.get("by") or "workbench"))
    return h._json(200 if res.get("ok") else 400, res)


ROUTES = {
    ("GET", "/api/health"): api_health,
    ("GET", "/api/overview"): api_overview,
    ("GET", "/api/accounts"): api_accounts,
    ("POST", "/api/accounts/toggle"): api_accounts_toggle,
    ("POST", "/api/accounts/add"): api_accounts_add,
    ("GET", "/api/accounts/provision"): api_accounts_provision_status,
    ("GET", "/api/machines"): api_machines,
    ("GET", "/api/runs"): api_runs,
    ("GET", "/api/pool-state"): api_pool_state,
    ("POST", "/api/dispatch"): api_dispatch,
    ("POST", "/api/backup"): api_backup,
    ("POST", "/api/rdp"): api_rdp,
    ("GET", "/api/rdp/preview"): api_rdp_preview,
    ("GET", "/api/rdp/default"): api_rdp_default,
    ("POST", "/api/rdp/default"): api_rdp_default,
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
