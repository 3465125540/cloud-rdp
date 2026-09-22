# 智能体工作台（Workbench）

一个**跑在本机的单页仪表盘**，把 cloud-rdp 这套「GitHub Actions 云桌面」的日常运维收进一个页面。

- **零依赖**：只用 Python 标准库（本机 Python 3.13），不用 `pip install`、不用 `npm install`。
- **本地优先**：默认只监听 `127.0.0.1`，不对外暴露；GitHub Token 只留在本机。
- **降级可见**：GitHub API / Tailscale / SMB 三条链路互相独立，挂哪条哪块面板显示「不可用」，其余照常。

---

## 1. 四大面板

| 面板 | 数据来源 | 能做什么 |
| --- | --- | --- |
| **GitHub 账号管理** | `scripts/pool-config.json` + 仓库 Actions Secrets 列表 + `pool-state` 分支 | 看每个账号的 Secret 是否就位、当前是主还是备、有没有在跑机；**一键启用/停用**账号（直接改 pool-config.json） |
| **机器运行实况** | Tailscale `status --json` + 远端 `D:\cloudrdp-sys\_state\pool-role.txt` / `job-start.txt` + `_snapshot\manifest.json` | 看哪些机器在线、Tailscale IP、角色（主/备/单机）、**已运行时长**、快照新鲜度、最后在线时间；**一键登录** 或 **查看信息**（弹窗显示 Tailscale IP / 用户名 / 密码，可一键复制） |
| **定时计划运行日志** | GitHub Actions API（`windows-rdp.yml` / `pool-coordinator.yml`） | 两个 workflow 的最近 25 次运行：状态、触发方式（定时/手动）、开始时间、用时、SHA，点「日志」跳 GitHub |
| **一键登录机器** | 生成 `.rdp` + `cmdkey` 预存凭据 + 唤起 `mstsc` | 点一下直接连上在线机器，免手输密码 |

---

## 2. 快速开始

```bat
:: 双击即可（会自动开浏览器）
workbench\start.cmd

:: 或者命令行
python workbench\server.py                 :: http://127.0.0.1:8787
python workbench\server.py --port 9000     :: 换端口
python workbench\server.py --no-open       :: 不自动开浏览器
python workbench\server.py --offline       :: 离线模式（不联网，自测用）
```

打开后默认 30 秒自动刷新，右上角可关。

### 自测

```bat
python workbench\selftest.py
```

离线起一个服务 + 单测纯函数，共 **93 项**，应全绿。不联网、不碰真机、不写你的桌面。

---

## 3. 配置

所有配置都有内置默认值。要覆盖，把 `config.example.json` 复制成 `config.json` 再改
（`config.json` 已在 `.gitignore` 里，不会入库）。

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `repo` / `ref` | `3465125540/cloud-rdp` / `main` | 池 hub 仓库 |
| `token_file` | 空 | 留空 = 自动发现（见下） |
| `proxy` | `auto` | `auto` = 探测 `127.0.0.1:7890`；也可写死代理地址或 `off` |
| `proxy_hosts` | `[]` | 列在这里的主机**先走代理**；其余先直连。哪条路失败会自动回退并记住 |
| `pool_config` | `scripts/pool-config.json` | 相对仓库根 |
| `tailscale_exe` | `C:\Program Files\Tailscale\tailscale.exe` | |
| `machine_prefix` | `github-rdp-server` | 只把以此开头的 Tailscale 节点当「我们的机器」 |
| `smb_base` | `D:\cloudrdp-sys` | 远端系统目录（读角色/快照用） |
| `rdp_user` / `rdp_password` | `a` / `a` | 与 `windows-rdp.yml` 的 `RDP_USERNAME/PASSWORD` 保持一致 |
| `rdp_launch` | `true` | 生成 `.rdp` 后是否自动唤起 mstsc |
| `rdp_store_cred` | `true` | 是否 `cmdkey` 预存凭据（免手输密码） |
| `snapshot_stale_minutes` | `90` | 快照超过这么久没更新 → 标黄 |

### Token 自动发现顺序

1. `config.json` 里的 `token_file`
2. 环境变量 `GH_TOKEN` / `GITHUB_TOKEN`
3. `gh auth token`（`gh` 在 PATH 或 `.tools/bin/gh.exe`）
4. 常见落盘位置：`../.tools/gh_token.txt`、`.tools/gh_token.txt`、`~/.workbuddy/gh_token.txt`

没找到 Token 也能跑：只读面板大多可用（限流更低），但**派发 workflow** 和**读 Secret 列表**会失败并给出提示。

---

## 4. 网络：直连 vs 代理

国内访问 GitHub 常见「一个域名通、另一个不通」。工作台的做法是**按主机择路 + 失败自动回退**：

- 每个主机第一次请求时，按 `proxy_hosts` 决定先试哪条路；
- 失败就试另一条；哪条成功就**记住**，后续直接用对的那条；
- `pool-state` 读取额外做了**双通道**：先 `raw.githubusercontent.com`，失败回退到 GitHub API 的 `contents` 接口（走 `api.github.com`，国内更稳）。

实测（本机）：`api.github.com` 直连 ~0.35s；`raw.githubusercontent.com` 时通时断，故用双通道兜底。

---

## 5. 一键登录是怎么实现的

`POST /api/rdp {ip, hostname}` 做三件事：

1. 在桌面写一个 `RDP-<host>-<ip>.rdp`（分辨率、剪贴板/磁盘重定向、`authentication level:i:0` 等都配好）；
2. `cmdkey /generic:TERMSRV/<ip> /user:a /pass:a` 把凭据存进 Windows 凭据管理器 → 连的时候**不弹密码框**；
3. `os.startfile()` 唤起 `mstsc`。

> 机器只能经 Tailscale 内网访问，tailnet 才是真正的安全边界，密码只当第二道门 —— 与 `windows-rdp.yml` 里的取舍一致。

界面上每台在线机器有两个按钮：**一键登录**（生成 + 预存凭据 + 唤起）和**查看信息**
（弹窗显示 `Tailscale IP :` / `Username     :` / `Password     :`，点任意一行复制该值，也可「复制全部」）。
状态列还会显示这台机器的**已运行时长**（读远端 `_state\job-start.txt`，`now - job 起点`）。

> 「查看信息」用的 `GET /api/conn-info?ip=...` 会把用户名/密码回给前端 —— 服务默认只监听
> `127.0.0.1`，仅本机可访问；别把 `host` 改成 `0.0.0.0` 再暴露到公网。

---

## 6. HTTP 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 服务与各链路健康状态 |
| GET | `/api/overview` | **一次拿齐**前端所需全部数据；`?refresh=1` 强制清缓存 |
| GET | `/api/accounts` | 账号池清单 + 每账号实时监测（凭证状态 / 在跑机数 / 最近 run） |
| POST | `/api/accounts/toggle` | `{id, enabled}` 启用/停用账号（写回 pool-config.json） |
| POST | `/api/accounts/add` | `{owner, repo, token_secret, id?, enabled?}` 新增账号（校验后原子写回 pool-config.json，不写 PAT 明文） |
| GET | `/api/machines` | 机器实况（含 `uptime_seconds` / `uptime_human` / `started_utc`） |
| GET | `/api/runs?workflow=all\|keepalive\|coordinator&limit=N` | Actions 运行记录 |
| GET | `/api/pool-state` | hub 发布的权威角色状态 |
| POST | `/api/dispatch` | `{target:"coordinator"\|"keepalive", inputs:{...}}` 触发 workflow |
| POST | `/api/rdp` | `{ip, hostname, launch?, store_cred?}` 一键登录 |
| GET | `/api/rdp/preview?ip=...` | 预览生成的 `.rdp` 文本（不落盘） |
| GET | `/api/conn-info?ip=...` | 连接信息（Tailscale IP / 用户名 / 密码），供「查看信息」弹窗用 |

---

## 7. 目录结构

```
workbench/
├── server.py             # 后端：标准库 HTTP 服务 + 全部 API
├── selftest.py           # 离线自测（93 项）
├── start.cmd             # 双击启动
├── config.example.json   # 配置样例（复制成 config.json 使用）
├── README.md
└── static/
    ├── index.html        # 单页仪表盘
    ├── styles.css        # 深色主题
    └── app.js            # 前端逻辑（原生 JS）
```

---

## 8. 常见问题

**Q：机器面板里「角色」和「快照」都是空的？**
A：这两项是经 SMB 读远端 `D:\cloudrdp-sys\_state\pool-role.txt` 与 `_snapshot\manifest.json` 得到的。
如果那台机器跑的是**账号池功能上线前**的旧版本（`pool-role.txt` 不存在），或者还没到第一次快照时间点（保活第 60 分钟才做首份），就会是空的。在线状态本身仍然准确。

**Q：机器列表里有 30 多台？**
A：Tailscale 里累积的历史节点都还在。默认勾了「**只看在线**」，取消勾选可以看到全部。

**Q：Secret 那一列显示「未知」？**
A：读 Actions Secret **名字**列表需要仓库 admin 权限的 Token。Token 权限不够时会显示「未知」而不是「缺失」，避免误判。

**Q：Secret 那一列显示「可能已配置」？**
A：说明 hub 仓库配了 **JSON 通道** Secret `POOL_TOKENS`（值形如 `{"账号登录名": "ghp_..."}`），而本账号没有同名的独立 Secret。GitHub 的 Secret **值永不回显**，工作台无法确认那个 JSON 里到底有没有这个 owner，所以既不敢标「已配置」、也不误报「缺失」。**以「凭证」列的协调器巡检结果为准** —— 协调器是真的拿 token 去调 API 了，最权威。若该列显示 `ok`，说明 token 已就位（只是来自 JSON 通道）。

**Q：新增账号时能填 PAT 吗？**
A：不能，也不该填。账号池里一账号 = 一个 fork，token 只以 **GitHub Actions Secret** 的形式存在（名字如 `POOL_TOKEN_<ID>`），值永不通过 API 返回、也永不写进 `pool-config.json`。新增账号表单只需填 owner / repo / Secret 名，之后去对应仓库配好同名 Secret 即可。

**Q：实时监测的「在跑机数 / 最近 run」从哪来？**
A：两条来源合并：① 协调器每 10 分钟巡检，把**每个账号**的明细（凭证状态 / 在跑机数 / 最近 run）发布到 `pool-state` 分支 —— 覆盖全部账号；② hub 账号本机有 token 时，工作台额外轮询 `/actions/runs` 做**实时**探测（更新鲜）。卡片底部会标数据新鲜度（如「2 分钟前 · 协调器」或「实时」）。刚新增的账号在下一次协调器巡检前，明细可能为空属正常。

**Q：派发按钮点了没反应？**
A：workflow_dispatch 触发后 GitHub 通常要 10~60 秒才创建 run。界面会在 12 秒后自动刷新一次，也可以手动点「刷新」。

**Q：能放到公网吗？**
A：不建议。它会用本机凭据读仓库、往远端机器写 `.rdp`。默认只监听 `127.0.0.1`；真要远程看，走 Tailscale 访问这台机器，而不是把它暴露到公网。
