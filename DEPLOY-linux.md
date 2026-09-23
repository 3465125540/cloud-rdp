# 在 Linux 服务器上部署「GitHub 虚拟机管理工作台」

> 目标：把本仓库里的 `workbench/`（工作台本体）跑在一台 **Linux 服务器**上，
> 用它远程查看 / 操作 GitHub Actions 上跑的 Windows 云桌面机队。
>
> 工作台是**纯 Python 标准库、零第三方依赖**的本地 Web 仪表盘（`http.server` + 原生 JS）。
> 本包已做 Linux 适配：远端文件改用 `smbclient`、一键登录改用 `xfreerdp`/`remmina`、
> Tailscale 走 PATH 里的 `tailscale`。

---

## 1. 它能做什么 / 依赖什么

| 面板 | 数据来源 | Linux 上需要 |
|---|---|---|
| 机器运行实况 | `tailscale status --json` | **tailscale**（且本机已加入同一 tailnet） |
| 快照新鲜度 / 运行时长 / 归属账号 | SMB 读远端 `D:\cloudrdp-sys\_state`、`_snapshot` | **smbclient**（`apt install smbclient`） |
| 一键备份 | 经 SMB 写 `_state\backup-request.txt`，机器保活循环取走执行 | **smbclient** + 机器跑新版 workflow |
| 一键登录（远程桌面） | 生成 `.rdp` 并唤起客户端 | 可选：**xfreerdp** 或 **remmina** |
| 账号管理 / 运行日志 / 池状态 | GitHub API（`api.github.com`）+ `raw.githubusercontent.com` | 出网 + 一个 GitHub **PAT** |

- **Python**：3.8+（只用标准库）。
- **网络**：能访问 `api.github.com`、`raw.githubusercontent.com`，并能到 Tailscale 内网（100.x）。
- **端口**：默认 `8899`。

> ⚠️ **安全第一**：工作台的 `/api/conn-info` 会返回机器的 **RDP 明文密码**。
> 只要这台服务器不是完全隔离的内网，就**必须**设置 `access_token`（见第 5 节）。

---

## 2. 快速开始

### 方式 A：一键脚本（推荐）

```bash
# 1) 把整个 zip 解压到服务器任意目录
unzip cloud-rdp-workbench-linux-v1.5.4.zip -d /tmp/cloud-rdp-src
cd /tmp/cloud-rdp-src

# 2) 跑安装脚本（默认装到 /opt/cloud-rdp，端口 8899）
sudo GH_TOKEN=ghp_你的PAT bash deploy/install.sh

#    自定义路径/端口：
#    sudo bash deploy/install.sh --dir /srv/cloud-rdp --port 9000
```

脚本会：检查依赖 → 复制源码 → 生成 `workbench/config.json`（含**随机 access_token**）→
写入 Token → 安装并启动 systemd 服务 `cloud-rdp-workbench`。**脚本是幂等的**，可重复执行。

完成后终端会打印访问地址与令牌：

```
访问地址 : http://<服务器IP>:8899/
访问令牌 : xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
首次打开 : http://<服务器IP>:8899/?token=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### 方式 B：手动跑（前台，便于调试）

```bash
cd /path/to/cloud-rdp
cp deploy/config.linux.json workbench/config.json
# 编辑 workbench/config.json：至少设置 access_token；有 PAT 就设 token_file
python3 workbench/server.py --no-open
# 浏览器打开 http://<服务器IP>:8899/?token=你的access_token
```

常用参数：

| 参数 | 说明 |
|---|---|
| `--host 0.0.0.0` | 监听所有网卡（默认 `127.0.0.1` 仅本机） |
| `--port 8899` | 端口 |
| `--config <路径>` | 指定配置文件（等价于环境变量 `WORKBENCH_CONFIG`） |
| `--no-open` | 不自动打开浏览器（服务器上必加） |
| `--offline` | 离线自测模式（不联网） |

---

## 3. 配置说明（`workbench/config.json`）

默认值全部在 `server.py` 的 `DEFAULT_CONFIG`，配置文件里**只写要覆盖的键**即可。
环境变量优先级最高：`WORKBENCH_HOST` / `WORKBENCH_PORT` / `WORKBENCH_REPO` /
`WORKBENCH_REF` / `WORKBENCH_TOKEN_FILE` / `WORKBENCH_PROXY` / `WORKBENCH_TAILSCALE_EXE`。

| 键 | 默认 | 说明 |
|---|---|---|
| `host` / `port` | `127.0.0.1` / `8899` | 监听地址与端口 |
| `open_browser` | `true` | 服务器上设 `false` |
| `repo` / `ref` | `3465125540/cloud-rdp` / `main` | 池 hub 仓库 |
| `token_file` | `""` | 存 PAT 的单行文本文件（见下） |
| `proxy` | `auto` | Linux 一般设 `none`（直连） |
| `pool_config` | `scripts/pool-config.json` | 账号池配置，**相对仓库根** |
| `state_branch` / `state_path` | `pool-state` / `state/pool-state.json` | 协调器发布的权威状态位置 |
| `tailscale_exe` | `tailscale` | 找不到会自动 `which` |
| `machine_prefix` | `github-rdp-server` | 只把这些前缀的 Tailscale 节点当「我们的机器」 |
| `smb_mode` | `auto` | `auto`=Windows 走 UNC / Linux 走 smbclient；可强制 `smbclient` |
| `smbclient_exe` / `smb_timeout` | `smbclient` / `25` | smbclient 路径与超时（秒） |
| `smb_share` / `smb_base` | `D$` / `D:\cloudrdp-sys` | 远端共享与系统目录 |
| `snapshot_stale_minutes` | `90` | 快照多久没更新算「陈旧」（黄标） |
| `access_token` | `""` | **非空即开启鉴权**，见第 5 节 |
| `rdp_user` / `rdp_password` | `a` / `a` | 机器上的登录账号（与 workflow 的 env 一致） |
| `rdp_client_cmd` | `""` | Linux 唤起 RDP 的命令模板，留空自动探测 |

### GitHub Token 的自动发现顺序

1. `token_file` 指定的文件；
2. 环境变量 `GH_TOKEN` 或 `GITHUB_TOKEN`；
3. `gh auth token`（装了 GitHub CLI 并登录过）；
4. 常见落盘位置：`<仓库根>/../.tools/gh_token.txt`、`<仓库根>/.tools/gh_token.txt`、`~/.workbuddy/gh_token.txt`。

推荐做法（systemd 部署）：

```bash
sudo mkdir -p /etc/cloud-rdp
echo 'ghp_你的PAT' | sudo tee /etc/cloud-rdp/gh_token.txt >/dev/null
sudo chmod 600 /etc/cloud-rdp/gh_token.txt
```

> PAT 需要 **`repo`** 权限（读仓库/Secrets/触发 workflow）。若只做只读查看，`public_repo` 也够看公开仓库。

---

## 4. Linux 与 Windows 的行为差异

| 能力 | Windows 工作台 | Linux 工作台 |
|---|---|---|
| 读远端文件 | 直接 `open("\\\\ip\\D$\\...")`（先 `net use` 预鉴权） | **`smbclient` 子进程**（密码走 `PASSWD` 环境变量，不落命令行） |
| 一键登录 | `mstsc /v:`（配 `Default.rdp` 认证级别=0 → 零弹窗） | **`xfreerdp` / `remmina`**（`rdp_client_cmd` 可自定义） |
| 证书警告修复 | `/api/rdp/default` 改注册表/Default.rdp | 不适用（Linux 客户端用 `/cert:ignore` 之类参数） |
| Tailscale | `C:\Program Files\Tailscale\tailscale.exe` | PATH 里的 `tailscale` |
| 生成 `.rdp` 文件 | 有（供 mstsc 用） | 无实际用途，仍可生成 |

**一键登录在 Linux 上的前提**：这台服务器本身通常**不**直接弹远程桌面窗口（它是无头服务器）。
所以更常见的用法是——用工作台**看状态 + 复制连接信息 + 一键备份**，真正连桌面时在你自己的
Windows/Mac 电脑上用 `mstsc`/Microsoft Remote Desktop 连那个 Tailscale IP。
若确实要在服务器上开窗口，需装桌面环境 + `xfreerdp`，并把 `rdp_client_cmd` 配好。

---

## 5. 访问与安全（**必读**）

### 5.1 开启访问令牌

`config.json` 里把 `access_token` 设成一串足够长的随机值（`install.sh` 会自动生成）：

```bash
python3 -c 'import secrets;print(secrets.token_urlsafe(32))'
```

开启后，**所有**请求都要带令牌，三种方式任一即可：

- 打开 `http://<服务器IP>:8899/?token=<令牌>`（会种一个 Cookie，之后免带）；
- 请求头 `X-Workbench-Token: <令牌>`；
- Cookie `wb_token=<令牌>`。

未带令牌会返回 **401**（API 返回 JSON，页面返回一段提示）。

### 5.2 更稳妥：只监听内网 / 走反向代理 + HTTPS

- 能内网访问就**别暴露公网**：`host` 设为内网 IP，或 `127.0.0.1` + SSH 隧道
  （`ssh -L 8899:127.0.0.1:8899 user@server` 后本地开 `http://127.0.0.1:8899/?token=...`）。
- 必须公网访问时，**用 Nginx/Caddy 反代 + TLS**，并只放行可信 IP：

```nginx
server {
    listen 443 ssl http2;
    server_name workbench.example.com;
    ssl_certificate     /etc/letsencrypt/live/workbench.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/workbench.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8899;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        # 工作台自身也开了 access_token，双保险
    }
}
```

- 防火墙只放行 443（或你改的端口），**不要**把 8899 直接对公网开放：

```bash
sudo ufw allow 443/tcp
sudo ufw deny 8899/tcp
```

---

## 6. 「一键备份」是怎么工作的

工作台无法直接给机器下命令（机器是 GitHub Actions runner，没有对外命令通道），
所以采用**请求文件轮询**：

```
[工作台]  --SMB写-->  机器 D:\cloudrdp-sys\_state\backup-request.txt
                                  │
                     机器保活循环（windows-rdp.yml 第 14 步）每分钟轮询
                                  │  取走即删（工作台靠「文件在不在」判断是否还在排队）
                                  ▼
                    主(primary/standalone)：sync-up.ps1  →  backup-snapshot.ps1 -Quick -Push
                    备(standby)          ：backup-snapshot.ps1 -Quick（不写 139）
                                  │
                                  ▼
                     写 _state\backup-done.txt 留痕
```

- 同步用 `scripts/sync-up.ps1` 的 `rclone copy --update`（只增不删）：只上传「新增 / 比远端更新」
  的文件，远端已存在的相同文件会被跳过，因此天然**避免重复上传**，也不会删除远端文件。
- 界面上：**机器运行实况 → 快照栏**。有快照时显示「多久之前 / 文件数 / 绝对时间」；
  下方是 **☁ 一键备份** 按钮（一次点击 = 增量同步到 139 + 快速快照推送）。
  点了之后按钮变「备份中…」，直到机器取走请求。
- **前提**：机器上跑的 workflow 必须是**支持该轮询的版本**（第 14 步含 `backup-request.txt` 检查）。
  旧机器不认这个文件，按钮会一直停在「已下发，等待执行」。
- 快照时间来自机器上的 `_snapshot/manifest.json`（`createdUtc`/`createdLocal`），
  工作台按**服务器本机时区**显示成 `MM-DD HH:MM`。
- 「GitHub 账号管理」的监测数据时间与「定时计划运行日志」的开始时间，统一按
  **实时北京时间（UTC+8）** 显示，形如 `2026/9/22-20:16`（绝对时间，非「X 小时前」）。

---

## 7. 常见问题（排错）

**Q：机器列表空 / Tailscale 面板红点。**
服务器没装 `tailscale`、没加入 tailnet、或 `tailscale status` 权限不足。
`tailscale status --json` 能正常输出即可。systemd 部署时服务默认以 root 跑，一般没问题。

**Q：快照 / 归属账号 / 运行时长读不到（显示「—」）。**
这是 SMB 链路问题。逐项排查：
1. 装了 smbclient？`smbclient -L //100.x.x.x -U a%a` 能列出共享吗？
2. 远端机器开着 445 端口、`D$` 共享可访问、账号密码与 `rdp_user/rdp_password` 一致？
3. 远端机器**在线**吗（离线机器读不到任何 `_state`）？
> 注意：SMB 读的是**内网 Tailscale IP**，服务器必须在同一 tailnet。

**Q：一键备份点了没反应 / 一直「已下发」。**
见第 6 节「前提」——机器上的 workflow 版本太旧。也可能是 SMB 写失败（看页脚错误）。

**Q：一键登录在服务器上没窗口。**
Linux 无头服务器本来就不会弹窗，属正常（见第 4 节）。用「查看信息」复制 IP/账号/密码，
在你自己的电脑上连。

**Q：`token_present: false`，账号/日志面板降级。**
没找到 PAT。按第 3 节配置 `token_file` 或 `GH_TOKEN` 环境变量后重启服务。

**Q：GitHub API 偶发失败（代理/网络）。**
`config.json` 的 `proxy` 设 `none` 强制直连，或设成你的代理地址
（如 `http://127.0.0.1:7890`）。

**查看日志 / 重启：**

```bash
journalctl -u cloud-rdp-workbench -f          # 实时日志
systemctl restart cloud-rdp-workbench         # 重启
systemctl status  cloud-rdp-workbench         # 状态
```

**跑自测（验证部署环境）：**

```bash
cd /opt/cloud-rdp && python3 workbench/selftest.py
# 期望输出： 结果：149 PASS / 0 FAIL
```

---

## 8. 升级 / 卸载

**升级**：把新包覆盖到安装目录（保留 `workbench/config.json`），重启服务。

```bash
sudo bash deploy/install.sh          # 幂等：不覆盖已有 config.json
sudo systemctl restart cloud-rdp-workbench
```

**卸载：**

```bash
sudo systemctl disable --now cloud-rdp-workbench
sudo rm -f /etc/systemd/system/cloud-rdp-workbench.service
sudo systemctl daemon-reload
sudo rm -rf /opt/cloud-rdp /etc/cloud-rdp
```

---

## 9. 目录结构（本包）

```
cloud-rdp/
├── DEPLOY-linux.md              ← 本文件
├── deploy/
│   ├── install.sh               # 一键安装脚本
│   ├── workbench.service        # systemd 单元模板
│   └── config.linux.json        # Linux 配置模板
├── workbench/                   # ★ 工作台本体
│   ├── server.py                # 后端（标准库 HTTP 服务）
│   ├── static/                  # 前端（index.html / app.js / styles.css）
│   ├── selftest.py              # 离线自测
│   └── config.example.json
├── scripts/
│   └── pool-config.json         # ★ 账号池配置（「数据库」；不含任何密钥）
├── .github/workflows/           # 机器侧 workflow（在 GitHub 上跑，不在本服务器）
│   ├── windows-rdp.yml
│   └── pool-coordinator.yml
└── README.md                    # 整套系统的详细说明
```
