# cloud-rdp

用 **GitHub Actions（私有仓库）** 跑一台临时 Windows 云主机，通过 **Tailscale** 组网，本地 `mstsc` 直连；
数据用 **rclone + AList** 桥接到 **中国移动云盘（139）**，实现跨会话持久化。

> ⚠️ 本方案不符合 GitHub Actions 官方用途定义（CI/CD），属于技术玩法。请阅读文末[风险声明](#风险声明)。

---

## 一、能力与限制

| 项 | 说明 |
|----|------|
| 配置 | 约 4 核 16G（`windows-latest`，实际以 runner 为准） |
| 单次时长 | **最长 6 小时**（GitHub 单 Job 硬上限） |
| 频率 | 私有仓库免费额度 2,000 分钟/月（按**原始分钟**计，不乘 2×）→ 约 **5~6 次满时长会话/月** |
| 触发 | **定时**（北京时间 08:30 / 13:30 两场）+ **手动**（Actions → Run workflow） |
| 数据 | `C:\data`：开机拉取、运行中每 10 分钟同步、关机前全量同步 |
| 整机快照 | 文件 / 注册表 / 软件清单 / 系统设置 / 快捷方式；开机基线 + 每 60 分钟 + 关机前抓取，下次开机自动还原 |
| 网络 | 走 Tailscale 内网（100.x.x.x），无需公网 IP |

---

## 二、前置准备

1. **Tailscale 账号** → https://tailscale.com/ （用微软账号登录最省事）
2. **GitHub 账号** → 建一个**私有**仓库（Public 会拿到无限额度，但风控风险显著上升，本项目默认私有）
3. **中国移动云盘账号** → https://yun.139.com/

---

## 三、配置 2 个 Secret + 1 个写死密码（截图级）

进入仓库 → **Settings** → 左侧 **Secrets and variables** → **Actions** → **New repository secret**。

> 说明：RDP 密码**不走 Secret**，直接写死在 `.github/workflows/windows-rdp.yml` 的 `env:` 里（当前值 `Rdp@2026#Nvd`）。只有下面 2 个走 Secret。

### 1. `TAILSCALE_AUTHKEY`

1. Tailscale 后台 → 左侧 **Settings** → **Keys** → **Generate auth key…**
2. 勾选 **Reusable**、**Ephemeral**，Expiration 选 **90 days**
3. 复制生成的 `tskey-auth-...`，填入 Secret

### 2. 密码与用户名（写死在 workflow，无需配 Secret）

打开 `.github/workflows/windows-rdp.yml`，改顶部 `env:` 两行即可：

- `RDP_USERNAME`：默认 `NvdAdmin`
- `RDP_PASSWORD`：默认 `Rdp@2026#Nvd`（改时**务必保留两侧引号**，`#` 在 YAML 里敏感）

改完提交推送，不需要任何 Secret。

### 3. `ALIST_139_AUTHORIZATION`（关键，约 15 天过期）

1. 浏览器登录 https://yun.139.com/
2. 按 **F12** 打开开发者工具 → **Application（应用）** 面板
3. 左侧 **Cookies** → 选 `https://yun.139.com`
4. 找到名为 **`Authorization`** 的项，复制它的值
5. ⚠️ **只复制 `Basic ` 后面的那段**（不含 `Basic` 和空格）
6. 粘贴进 Secret 值

> 备用取法：F12 → **Network（网络）** → 筛选 `hcy/file/list` → 请求标头里的 `Authorization`，同样只取 `Basic ` 之后的部分。

---

## 四、部署与使用

### 1. 上传代码

把本仓库推送到你的**私有** GitHub 仓库（命令见文末）。

### 2. 启动云主机

**① 定时自动（默认开启）** —— workflow 内置两个 cron，北京时间每天自动开两次：

| 场次 | 北京时间开机 | UTC cron | 自动关机 |
|------|--------------|----------|----------|
| 早场 | **08:30** | `30 0 * * *` | 11:30 |
| 午场 | **13:30** | `30 5 * * *` | 17:30 |

到窗口结束时间会**自动停止**并做最后一次全量同步（不会两场重叠）。

**② 手动** —— 仓库顶部 → **Actions** → 左侧 **Windows Cloud RDP** → **Run workflow**（手动触发跑满 5 小时 50 分）。

启动后等约 6–10 分钟，展开 **9. 估算额度 + 打印连接信息** 步骤记下 **Tailscale IP**；也可在 https://login.tailscale.com/admin/machines 看到 `github-rdp-server*` 设备。

> ⚠️ **额度警告（实测口径）**：GitHub Free 私有仓库 **2000 分钟/月**，
> 官方 Billing API 显示额度**按原始分钟抵扣、不乘 Windows 2× 倍率**
> （实测：本月 1858 分钟 Windows 用量 → `grossAmount` $18.58、`netAmount` **$0.00**，全额抵扣）。
> 一次满时长 run ≈ **350 分钟** → 整月约 **5~6 次**。
> 额度耗尽后 Actions 直接停摆、**不会报错**，直到次月 1 号重置。
> 想长期每天跑，必须换**公开仓库**（无限额度，但有风控/封号风险）或**真·云服务器**。

> 💡 **内置额度告警**：每次开机时 step 8 会算出本月已用额度并显示剩余 ——
> **≤50% 变黄、≤20% 变红**。
> - **首选数据源**：官方 Billing API `GET /users/{owner}/settings/billing/usage?year=&month=`
>   → 账号级准确数字，**需要 `user` scope 的令牌**（存于 Secret `GH_BILLING_TOKEN`）
> - **回退数据源**：本仓库 run 历史求和（`GITHUB_TOKEN` + `actions: read`）
>   → 只算本仓库，会**严重低估**（实测：真实 1858 分钟，回退只算出 181）
> - 脚本：`scripts/quota-report.ps1`，输出的 `QUOTA_SOURCE` 会显示实际用了哪个源

### 3. 本地连接

1. **前提**：本地电脑已安装 Tailscale 并登录**同一账号**
2. `Win + R` → `mstsc` → 计算机填 **Tailscale IP** → 连接
3. 用户名 `NvdAdmin`，密码为 workflow 里写死的 `RDP_PASSWORD`（默认 `Rdp@2026#Nvd`）
4. 证书警告点「是/继续」

### 4. 数据与整机状态持久化

云主机是**一次性**的：每次开机都是全新 Windows 镜像。所以「上次关机前的样子」必须靠
**自己抓取 + 自己还原**。本项目用两条独立管线覆盖：

#### ① 数据管线（`C:\data`，高频）

- 云主机里用 **`C:\data`** 存数据（**公共桌面已放 `CloudData` 快捷方式**，双击即达）
- **开机自动恢复**：每次启动自动把 139 云盘的 `/CloudRDP` 拉回 `C:\data`
- 运行中每 10 分钟推送到 139 云盘；关闭会话后还会做一次全量推送
- 恢复结果会显示在 **「9. 估算额度 + 打印连接信息」** 步骤里：

  | 状态 | 含义 |
  |------|------|
  | `OK` | 恢复成功（日志打印文件数 / 大小） |
  | `EMPTY` | 远端还没有数据（首次运行正常） |
  | `FAILED` | 恢复失败 —— 多半是 139 Authorization 过期；`C:\data` 是空的，**别在上面存重要东西** |

- 恢复失败时会在 `C:\data` 留一个 `_RESTORE_FAILED.txt` 标记，并**红色高亮**警告
- 恢复失败**不会**挡住 RDP 启动（脚本永远返回 0），保证机器始终可用

#### ② 整机快照管线（文件 / 注册表 / 设置，低频）

覆盖 `C:\data` 之外的一切「关机前的样子」，存到 139 的 **`/_snapshot`**（与 `/CloudRDP` 分开）。

**抓取时机**：开机后基线、保活期间**每 60 分钟**、**关机前全量**（`if: always()`，取消也会跑）。

**抓什么**（全部可在 `scripts/snapshot-config.json` 里改，无需改脚本）：

| 类别 | 内容 |
|------|------|
| 文件 | `C:\tools`、`C:\scripts`、`C:\apps`、用户 `Desktop/Documents/Downloads/Pictures/Videos/Music/Favorites`、`AppData\Roaming\...\Start Menu`、`.ssh`、`.aws`、`.config`、`.vscode\extensions`、`.gitconfig` 等 |
| 注册表 | RDP 用户的 **HKCU** 子键（`Software`、`Control Panel\Desktop/Colors/International/Mouse/Keyboard`、`Environment`、`Console`、`Explorer\Advanced`）+ 机器级 `TimeZoneInformation`、`Session Manager\Environment`、`Nls\Language/Locale` |
| 软件清单 | `winget export` + 注册表 Uninstall 扫描（**清单**，不是二进制；重装靠 winget） |
| 系统设置 | 时区、区域、电源方案、壁纸（壁纸文件一并带走） |
| 快捷方式 | 公共桌面 / 用户桌面 / 用户开始菜单（`*.lnk` / `*.url`） |

**还原时机（关键设计）**：分两个作用域，绕开 Windows「用户配置文件跨机还原」的老大难：

| 作用域 | 何时 | 以谁的身份 | 干什么 |
|--------|------|-----------|--------|
| `machine` | 开机第 8 步 | `runneradmin` | 拉快照、还原机器级文件、导入机器注册表、恢复时区/电源、还原公共桌面，并**注册一个登录任务** |
| `user` | RDP 用户**首次登录**时 | `NvdAdmin` | 还原个人目录文件、导入 HKCU、还原个人快捷方式与壁纸，然后**自注销任务**（只跑一次） |

> 为什么要分两步：`NvdAdmin` 的 HKCU 与用户配置文件在他首次登录前**并不存在**，
> 以 `runneradmin` 身份硬写会被 Windows 判为异常 profile 并在登录时重建，还原等于白做。
> 顺带好处：HKCU 导出时会把 SID 归一化成 `__RDPUSER__` 占位符，换机后 SID 变了也能正确导入。

**还原状态**显示在同一处连接信息里：`OK` / `PARTIAL` / `EMPTY` / `FAILED`。

**已知边界**（做不到的，别指望）：

- 已装软件的**二进制本体**不会回来 —— 只还原清单，需要时用 `winget import` 重装（`restore.installApps` 默认关闭）
- 需要**授权码/硬件绑定**的商业软件，激活状态无法复刻
- Windows 更新状态、驱动、运行中的进程状态不涉及
- 浏览器 profile（Chrome/Edge 的 `User Data`）**刻意不抓**（体积以 GB 计、缓存为主），需要重新登录
- 快照体积上限默认 **8 GB**（`files.maxTotalMB`），超出会跳过后续目录并告警

---

## 五、目录结构

```
cloud-rdp/
├── .github/workflows/windows-rdp.yml   # 主工作流（12 步）
└── scripts/
    ├── setup-rclone.ps1                # 安装并配置 rclone
    ├── setup-alist.ps1                 # 部署 AList，挂载 139 云盘
    ├── sync-down.ps1                   # 139 → C:\data（数据恢复）
    ├── sync-up.ps1                     # C:\data → 139（数据备份）
    ├── snapshot-config.json            # 整机快照清单（改这里调整备份范围）
    ├── backup-snapshot.ps1             # 抓取整机状态 → C:\_snapshot → 139/_snapshot
    ├── restore-snapshot.ps1            # 还原整机状态（machine / user 两个作用域）
    └── quota-report.ps1                # Actions 额度估算与告警
```

139 云盘内的存放位置：

| 路径 | 内容 |
|------|------|
| `CloudRDP/` | 用户数据（`C:\data` 的镜像） |
| `_snapshot/` | 整机快照（文件 / 注册表 / 软件清单 / 设置 / 快捷方式） |

---

## 六、常见问题

| 现象 | 原因 | 解决 |
|------|------|------|
| 第 6 步报「创建 139 存储失败」 | `Authorization` 过期或复制多了 `Basic` | 重新获取 Authorization，只取 `Basic ` 后那段，更新 Secret |
| 第 6 步报驱动不存在 | AList 版本驱动名不同 | 日志会打印可用驱动列表，改 `setup-alist.ps1` 里的 `$driverKey` |
| `sync-down` 退出码非 0 | 首次运行远端为空（正常）/ Authorization 过期 | 首次可忽略；否则更新 Secret |
| 上传大文件卡住 | 139 走 WebDAV 有 5 分钟超时 | 单文件建议 <500MB；超大文件用 139 官方客户端 |
| 连不上 100.x.x.x | 本地没登录 Tailscale | 本地客户端登录同一账号，`tailscale status` 检查 |
| 会话突然断开 | 6 小时到点，Job 被回收 | 正常，重新 Run workflow |
| 整机还原显示 `PARTIAL` | 个别目录/注册表键还原失败（日志有明细） | 看日志 `[restore]` 行定位；多为该目录不存在或权限问题 |
| 登录后个人配置没回来 | 登录还原任务失败或未触发 | 查「任务计划程序」里的 `CloudRDP-RestoreUser`；日志在首次登录时不可见，可手动跑 `C:\_snapshot\_tools\restore-snapshot.ps1 -Scope user` |
| 关机前的改动丢了 | Job 被**硬杀**（超时/取消太快），收尾步骤没跑完 | 保活期每 60 分钟会自动抓一次快照，最多丢 1 小时内改动 |
| 快照没上传 | 快照超过 `files.maxTotalMB`（默认 8GB） | 日志会告警并跳过后续目录；调大上限或从清单里删掉大目录 |

---

## 七、风险声明

- **非官方用途**：用 GitHub Actions 跑个人云桌面不符合其服务条款，长期使用可能被限流/封号。本仓库默认**私有**以降低暴露面，但**无法保证账号安全**。
- **不要存重要/隐私数据**：数据经 AList 非官方桥接写入 139 云盘，链路不保证稳定与安全。
- **快照含敏感文件**：`.ssh`、`.aws`、`.config`、`.vscode` 等会被同步到 139 云盘。若不愿外传，
  请在 `scripts/snapshot-config.json` 的 `files.dirs` 里删掉对应条目（改完提交即可）。
- **Authorization 约 15 天过期**：需定期手动更新 Secret，否则工作流会在第 6 步失败。
- **额度有限**：私有仓库约 5~6 次满时长会话/月，用完即停（Actions 会**静默停摆、不报错**）。
- **机器是一次性的**：Job 结束即销毁。已纳入快照的内容（见第四节）可自动还原，其余会丢失。

> 如果需要**稳定可靠、数据持久、可定时开关机**的云主机，请直接购买低价 VPS（约 $5–15/月），比本方案靠谱得多。

---

## 八、推送到 GitHub（私有仓库）

```bash
# 在本目录下执行
git init
git add .
git commit -m "init: cloud-rdp"
git branch -M main

# 先在 GitHub 网页新建一个 Private 仓库，再把下面 URL 换成你的
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

推送后别忘了在 **Settings → Secrets and variables → Actions** 配置 **3 个 Secret**：

| Secret | 用途 | 是否必需 |
|--------|------|----------|
| `TAILSCALE_AUTHKEY` | Tailscale 组网 | ✅ 必需 |
| `ALIST_139_AUTHORIZATION` | 139 云盘授权（约 15 天过期） | ✅ 必需 |
| `GH_BILLING_TOKEN` | 查官方 Billing API 拿账号级额度（需 `user` scope） | 可选（缺省回退本仓库估算） |

RDP 密码写死在 workflow 里，无需配。
