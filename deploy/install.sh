#!/usr/bin/env bash
# ============================================================================
#  GitHub 虚拟机管理工作台 —— Linux 一键部署脚本
#  用法（需要 root）：
#      sudo bash deploy/install.sh                 # 装到 /opt/cloud-rdp，端口 8787
#      sudo bash deploy/install.sh --dir /srv/cloud-rdp --port 9000
#      sudo GH_TOKEN=ghp_xxx bash deploy/install.sh   # 顺带写入 GitHub Token
#
#  幂等：可重复执行（已存在的 config.json / token 不会被覆盖）。
# ============================================================================
set -euo pipefail

INSTALL_DIR="/opt/cloud-rdp"
PORT="8787"
SERVICE_NAME="cloud-rdp-workbench"
TOKEN_FILE="/etc/cloud-rdp/gh_token.txt"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)  INSTALL_DIR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

SRC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log()  { printf '\033[36m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo bash deploy/install.sh）"

# ---------- 1. 依赖检查 ----------
log "检查依赖…"
command -v python3 >/dev/null 2>&1 || die "缺少 python3，请先 apt install -y python3"
PYBIN="$(command -v python3)"
PYVER="$("$PYBIN" -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
"$PYBIN" -c 'import sys; raise SystemExit(0 if sys.version_info>=(3,8) else 1)' \
  || die "Python 版本过低（$PYVER），需要 3.8+"

MISSING=()
command -v smbclient >/dev/null 2>&1 || MISSING+=("smbclient   # 读远端机器 _state/_snapshot（必需）")
command -v tailscale >/dev/null 2>&1 || MISSING+=("tailscale   # 发现在线机器节点")
command -v xfreerdp  >/dev/null 2>&1 || MISSING+=("freerdp2-x11 # 「一键登录」唤起远程桌面（可选）")
if [ "${#MISSING[@]}" -gt 0 ]; then
  warn "以下可选/必需组件未安装（按需补）："
  for m in "${MISSING[@]}"; do echo "        - $m"; done
  warn "Debian/Ubuntu 参考： apt install -y smbclient freerdp2-x11"
fi

# ---------- 2. 部署源码 ----------
log "部署源码到 $INSTALL_DIR …"
mkdir -p "$INSTALL_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude '.git' --exclude '__pycache__' --exclude '*.pyc' \
    --exclude 'workbench/config.json' \
    "$SRC_ROOT"/ "$INSTALL_DIR"/
else
  # 没有 rsync 就用 cp（不删除多余文件，够用）
  cp -a "$SRC_ROOT"/. "$INSTALL_DIR"/
  rm -rf "$INSTALL_DIR/.git" "$INSTALL_DIR"/**/__pycache__ 2>/dev/null || true
fi

# ---------- 3. 生成 config.json ----------
CFG="$INSTALL_DIR/workbench/config.json"
if [ -f "$CFG" ]; then
  log "已存在 $CFG —— 保留不覆盖"
else
  log "生成 $CFG（含随机 access_token）"
  TOKEN="$("$PYBIN" -c 'import secrets;print(secrets.token_urlsafe(32))')"
  "$PYBIN" - "$INSTALL_DIR/deploy/config.linux.json" "$CFG" "$PORT" "$TOKEN_FILE" "$TOKEN" <<'PY'
import json, sys
src, dst, port, tokfile, token = sys.argv[1:6]
cfg = json.load(open(src, encoding="utf-8"))
cfg["port"] = int(port)
cfg["token_file"] = tokfile
cfg["access_token"] = token
json.dump(cfg, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  ACCESS_TOKEN="$TOKEN"
fi

# ---------- 4. GitHub Token（可选）----------
mkdir -p "$(dirname "$TOKEN_FILE")"
if [ -n "${GH_TOKEN:-}" ]; then
  printf '%s' "$GH_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  log "已写入 GitHub Token → $TOKEN_FILE"
elif [ -f "$TOKEN_FILE" ]; then
  log "沿用已有 Token 文件 $TOKEN_FILE"
else
  warn "未提供 GH_TOKEN —— 部分面板会降级（匿名只读）。"
  warn "稍后可手动： echo ghp_xxx > $TOKEN_FILE && chmod 600 $TOKEN_FILE && systemctl restart $SERVICE_NAME"
fi

# ---------- 5. 安装 systemd 服务 ----------
UNIT_SRC="$INSTALL_DIR/deploy/workbench.service"
UNIT_DST="/etc/systemd/system/${SERVICE_NAME}.service"
if [ -f "$UNIT_SRC" ] && command -v systemctl >/dev/null 2>&1; then
  log "安装 systemd 服务 → $UNIT_DST"
  # 替换：安装路径 + python3 实际路径（发行版可能装在 /usr/local/bin 等）
  sed -e "s#/opt/cloud-rdp#$INSTALL_DIR#g" -e "s#/usr/bin/python3#$PYBIN#g" "$UNIT_SRC" > "$UNIT_DST"
  # 端口可能与默认不同，同步进 unit 的环境变量
  sed -i "s#^Environment=WORKBENCH_PORT=.*#Environment=WORKBENCH_PORT=$PORT#" "$UNIT_DST"
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME" || warn "启动失败，请查：journalctl -u $SERVICE_NAME -n 50 --no-pager"
  log "服务状态："
  systemctl --no-pager --full status "$SERVICE_NAME" | head -12 || true
else
  warn "未找到 systemd（$UNIT_SRC）—— 手动启动："
  echo "        cd $INSTALL_DIR && WORKBENCH_CONFIG=$CFG $PYBIN workbench/server.py --no-open"
fi

echo
log "部署完成 ✅"
echo "       访问地址 : http://<服务器IP>:$PORT/"
if [ -n "${ACCESS_TOKEN:-}" ]; then
  echo "       访问令牌 : $ACCESS_TOKEN"
  echo "       首次打开 : http://<服务器IP>:$PORT/?token=$ACCESS_TOKEN"
fi
echo "       配置文件 : $CFG"
echo "       日志查看 : journalctl -u $SERVICE_NAME -f"
echo "       详细说明 : $INSTALL_DIR/DEPLOY-linux.md"
