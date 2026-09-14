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
| 数据 | `D:\a\cloud-rdp`：开机拉取、运行中每 10 分钟同步、关机前全量同步 |
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

启动后等约 6–10 分钟，展开 **11. 估算额度 + 打印连接信息** 步骤记下 **Tailscale IP**；也可在 https://login.tailscale.com/admin/machines 看到 `github-rdp-server*` 设备。

> ⚠️ **额度警告（实测口径）**：GitHub Free 私有仓库 **2000 分钟/月**，
> 官方 Billing API 显示额度**按原始分钟抵扣、不乘 Windows 2× 倍率**
> （实测：本月 1858 分钟 Windows 用量 → `grossAmount` $18.58、`netAmount` **$0.00**，全额抵扣）。
> 一次满时长 run ≈ **350 分钟** → 整月约 **5~6 次**。
> 额度耗尽后 Actions 直接停摆、**不会报错**，直到次月 1 号重置。
> 想长期每天跑，必须换**公开仓库**（无限额度，但有风控/封号风险）或**真·云服务器**。

> 💡 **内置额度告警**：每次开机时 step 11 会算出本月已用额度并显示剩余 ——
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

#### ① 数据管线（`D:\a\cloud-rdp`，高频）

- 云主机里用 **`D:\a\cloud-rdp`** 存数据（**公共桌面已放 `CloudData` 快捷方式**，双击即达）
- **开机自动恢复**：每次启动自动把 139 云盘的 `/AI文件库/CloudRDP` 拉回 `D:\a\cloud-rdp`
- 运行中每 10 分钟推送到 139 云盘；关闭会话后还会做一次全量推送
- 恢复结果会显示在 **「9. 估算额度 + 打印连接信息」** 步骤里：

  | 状态 | 含义 |
  |------|------|
  | `OK` | 恢复成功（日志打印文件数 / 大小） |
  | `EMPTY` | 远端还没有数据（首次运行正常） |
  | `FAILED` | 恢复失败 —— 多半是 139 Authorization 过期；`D:\a\cloud-rdp` 是空的，**别在上面存重要东西** |

- 恢复失败时会在 `D:\a\cloud-rdp` 留一个 `_RESTORE_FAILED.txt` 标记，并**红色高亮**警告
- 恢复失败**不会**挡住 RDP 启动（脚本永远返回 0），保证机器始终可用

#### ② 整机快照管线（文件 / 注册表 / 设置，低频）

覆盖 `D:\a\cloud-rdp` 之外的一切「关机前的样子」，存到 139 的 **`/AI文件库/_snapshot`**（与 `/AI文件库/CloudRDP` 分开）。

**抓取时机**：开机后基线、保活期间**每 60 分钟**、**关机前全量**（`if: always()`，取消也会跑）。

**推送后自校验**：`rclone sync` 成功后会回读远端（`rclone size`），日志打印
`远端校验：N 个文件 / X MB（本地 M 个 / Y MB）` 并输出 `SNAPSHOT_VERIFY` ——
这是「快照确实落到 139」的日志证据，不用另外登录云盘确认。

**抓什么**（全部可在 `scripts/snapshot-config.json` 里改，无需改脚本）：

| 类别 | 内容 |
|------|------|
| 文件 | `C:\scripts`、`C:\apps`、用户 `Desktop/Documents/Downloads/Pictures/Videos/Music/Favorites`、`AppData\Roaming\...\Start Menu`、`.ssh`、`.aws`、`.config`、`.vscode\extensions`、`.gitconfig` 等 |
| 注册表 | RDP 用户的 **HKCU** 子键（`Software`、`Control Panel\Desktop/Colors/International/Mouse/Keyboard`、`Environment`、`Console`、`Explorer\Advanced`）+ 机器级 `TimeZoneInformation`、`Session Manager\Environment`、`Nls\Language/Locale` |
| 软件清单 | `winget export` + 注册表 Uninstall 扫描（**清单**，不是二进制） |
| 安装型程序 | **程序目录本体** + 逐程序 Uninstall 注册表键（见 ⑧；只备份「用户装的」，镜像自带的约 120 GB 绝不碰） |
| 系统设置 | 时区、区域、电源方案、壁纸（壁纸文件一并带走） |
| 快捷方式 | 公共桌面 / 用户桌面 / 用户开始菜单（`*.lnk` / `*.url`） |

> ⚠️ **不要加入 `C:\tools`** —— 那是 GitHub runner 镜像**自带**的工具目录（Apache24 / nginx-* 等，
> 实测 **240 MB / 1087 文件**），不是用户数据。备份它纯浪费带宽（一次推送多花 ~10 分钟），
> 还原时还会用旧版覆盖 runner 自带的版本。`snapshot-config.json` 里已注明。

**还原时机（关键设计）**：分两个作用域，绕开 Windows「用户配置文件跨机还原」的老大难：

| 作用域 | 何时 | 以谁的身份 | 干什么 |
|--------|------|-----------|--------|
| `machine` | 开机第 9 步 | `runneradmin` | 拉快照、还原机器级文件、导入机器注册表、恢复时区/电源、还原公共桌面，并**注册一个登录任务** |
| `user` | RDP 用户**首次登录**时 | `NvdAdmin` | 还原个人目录文件、导入 HKCU、还原个人快捷方式与壁纸，然后**自注销任务**（只跑一次） |

> 为什么要分两步：`NvdAdmin` 的 HKCU 与用户配置文件在他首次登录前**并不存在**，
> 以 `runneradmin` 身份硬写会被 Windows 判为异常 profile 并在登录时重建，还原等于白做。
> 顺带好处：HKCU 导出时会把 SID 归一化成 `__RDPUSER__` 占位符，换机后 SID 变了也能正确导入。

**还原状态**显示在同一处连接信息里：`OK` / `PARTIAL` / `EMPTY` / `FAILED`。

**已知边界**（做不到的，别指望）：

- 需要**授权码/硬件绑定**的商业软件，激活状态无法复刻
- Windows 更新状态、驱动、运行中的进程状态不涉及
- 浏览器 profile（Chrome/Edge 的 `User Data`）**刻意不抓**（体积以 GB 计、缓存为主），需要重新登录
- 快照体积上限默认 **8 GB**（`files.maxTotalMB`），超出会跳过后续目录并告警
- 已装软件的**二进制本体**：可移动程序**直接搬运**（见 ③）、安装型程序**目录级备份 + junction 还原**（见 ⑧）、
  其余靠**后台 winget 重装**（见 ⑤）。三条路互补；覆盖不到的主要是「需授权码 / 硬件绑定」的商业软件

#### ③ 可移动程序：识别 → 搬运 → 按原路径还原

「绿色/便携」程序（非 MSI 安装、自包含目录）会被**搬进数据目录**一起备份，还原时**放回原安装路径**。

- **识别**（默认保守，宁可漏不可误移）：扫 Uninstall 注册表，要求**同时**满足
  非 MSI（`UninstallString` 不含 `msiexec`、`WindowsInstaller≠1`）、非系统组件、`Publisher` 非微软、
  名字不命中黑名单（VC++ Redist / .NET Runtime / Windows SDK / Edge / WebView2…）、
  `InstallLocation` 存在且**不在**系统目录（`C:\Windows`、`C:\Program Files*`、`C:\ProgramData`、`WindowsApps`）、
  目录下有 `.exe`、体积 ≤ `portable.maxMBPerApp`。辅层再扫 `portable.scanRoots`（默认 `C:\apps`、`D:\apps`）。
- **搬运**：暂存到 **`D:\a\cloud-rdp\_portable\<原路径镜像>`**（如 `C:\apps\Foo` → `_portable\C\apps\Foo`），
  **默认 `copy` 不是 move** —— move 会破坏正在运行的机器（快捷方式/注册表引用失效）。
  高级用法 `portable.mode: "relocate"`：拷贝成功后把原目录换成指向副本的 **junction**，只留一份实体（默认关闭）。
- **原路径元数据**（三处一致，权威字段 `originalPath`）：
  `D:\a\cloud-rdp\_portable\_manifest.json`、`D:\cloudrdp-sys\_snapshot\apps\portable.json`、`manifest.json` 的 `apps.portable[]`。
- **还原**：`robocopy <暂存>\<镜像> → originalPath`，按 machine/user 作用域分流。
- 开关：`snapshot-config.json` 的 `portable.enabled` / `mode` / `scanRoots` / `blocklist` / `maxMBPerApp`。
  默认只在**收尾全量**快照里采集（`portable.captureInQuick=false`，避免每 60 分钟重复搬）。

#### ④ 预还原（还原前的一步）

开机第 9 步跑 `scripts/pre-restore.ps1 -Pull`，负责「把**关机前的完整状态**校验清楚、准备就绪，再驱动全量还原」：

| 阶段 | 做什么 |
|------|--------|
| 1 拉取 | 从 139 把快照拉到 `D:\cloudrdp-sys\_snapshot`（原 restore 的 `-Pull` 前移到这里） |
| 2 校验 | manifest 可解析/版本兼容、各 `files/<镜像>` 齐全、winget/portable 清单可解析 → `SNAPSHOT_PREVALIDATE` |
| 3 规划 | 生成 `D:\cloudrdp-sys\_snapshot\restore-plan.json`：每条 = **类型 / 原路径 / 存储路径 / 作用域**，并打印构成摘要 |
| 4 准备 | 建好数据目录、`_portable`、各还原目标的父目录 |
| 5 回滚 | 把将被覆盖的注册表键导出到 `D:\cloudrdp-sys\_snapshot\_rollback\<时间戳>\` + `rollback.json`（只记录现状，不整目录拷贝） |
| 6 钩子 | 执行 `restore.preCommands[]`（你在 `snapshot-config.json` 里写的自定义命令，**失败仅告警不阻断**） |
| 7 驱动 | 调用 `restore-snapshot.ps1 -Scope machine` 完成真正的机器级还原 |

- 只想校验不还原：`pre-restore.ps1 -SkipRestore`；只想空跑：`-DryRun`
- `restore.preCommands` 示例：`"Stop-Service -Name Spooler -Force"`、`"taskkill /IM foo.exe /F"`

#### ⑤ 软件重装（后台异步，不阻塞连接）

`restore.installApps` **默认开启**。还原后第 10 步调 `scripts/reinstall-apps.ps1 -Background`：

- 读 `D:\cloudrdp-sys\_snapshot\apps\winget-export.json`，**逐包** `winget install --id <id> -e --silent`，**每包独立 try/catch 失败不中断**
- **用 `Start-Process` 拉起后台进程后立即返回** → 第 11 步的连接信息**秒出**，你马上就能连 RDP，装包在后台继续
- 日志 `D:\cloudrdp-sys\_snapshot\_logs\apps-reinstall.log`；进度 `D:\cloudrdp-sys\_snapshot\_logs\apps-status.json`
- 临时关闭：`Run workflow` 时把 `install_apps` 填 `false`，或改 `restore.installApps`
- 限量试跑：`restore.maxPackages`（0 = 不限）

#### ⑥ 139 侧路径与迁移

数据/快照都放在 **`全部文件 > AI文件库`** 下：

```
全部文件/
├── AI文件库/                 ← 目标位置
│   ├── CloudRDP/             ← 用户数据
│   └── _snapshot/            ← 整机快照
└── CloudRDP/  _snapshot/     ← 老位置（迁移后保留兜底）
```

- 启动时会**预检** `AI文件库` 是否存在；**缺失就明确报错、不静默创建**（避免建出影子目录）
- **一次性迁移**：`Run workflow` 时把 `migrate_139` 填 `true`，第 7 步会 `rclone copy`（**不 move**）把老数据搬到新位置；
  幂等守卫：仅当「新路径为空 且 老路径非空」才执行。老数据原样保留，可随时切回
- **备选「根 ID 法」**：若不想让远端路径出现中文，可把 Secret/环境变量 `ALIST_139_ROOT_FOLDER_ID` 设为
  「AI文件库」的**文件夹 ID**（139 网页 F12 从请求里取），AList 的 `/cloudrdp` 会直接映射到该文件夹，
  远端路径即回归纯 ASCII（`alist:/cloudrdp/CloudRDP`），脚本原生支持，无需改代码

#### ⑦ C 盘策略：守住「我们的增量 ≤ 30%」

**先说清一个硬事实**：GitHub 托管的 Windows runner，C 盘 **150 GB 里约 120 GB 是镜像自带**的
（Visual Studio 2022 / Android SDK / `hostedtoolcache` / Azure CLI …），**开机就是约 80%**。
这个基线动不了（删它要 10–25 分钟，还会破坏依赖这些工具链的程序，Windows 更新也可能失败）。
所以「C 盘占用 ≤ 30%」字面做不到 —— 本项目守的是**我们产生的那部分**：

```
增量 = 当前 C: 已用 − 开机基线已用   ≤   基线可用空间 × 30%   （默认约 9.3 GB）
```

怎么做到：

| 措施 | 说明 |
|------|------|
| **产物全落 D 盘** | 数据 `D:\a\cloud-rdp`；rclone / AList / 快照暂存 / 程序实体全在 `D:\cloudrdp-sys`。C 盘上不留我们的东西 |
| **磁盘守卫** | `scripts/disk-guard.ps1`：开机记基线（第 0b 步）→ 打印连接信息前（第 10b 步）、保活期每 30 分钟、收尾（第 13 步）各执行一次 |
| **安全清理** | 超限时清临时目录、Windows 更新缓存、安装包残留、旧版 `C:\_snapshot` 遗留；**绝不触碰**数据目录 / 快照暂存 / 系统目录（有父目录保护） |
| **junction 还原** | 装到 C 盘的程序，还原时实体落 D 盘、原路径建 junction → 原路径照常可用，**C 盘零增长**（见 ⑧） |

连接信息里会实时显示：

```
  C 盘占用     : 80.2%  (120.4 / 150.1 GB)   本次增量 12 MB / 上限 9298 MB
  D 盘可用     : 146.9 GB  (数据 / 快照 / 程序实体都在 D 盘)
```

- 状态：`DISK_GUARD_STATUS` = `BASELINE` / `OK` / `FIXED` / `OVER`；`OVER` 会**红色高亮**并给出提示
- 阈值：改 `snapshot-config.json` 的 `disk.maxIncrementalPercent`（或用 `disk.maxIncrementalMB` 设绝对上限）
- 脚本**永不返回非 0**，不会因为磁盘告警挡住 RDP 启动

#### ⑧ 安装型程序复刻：备份目录 + Uninstall 注册表 → junction 还原

装在 `Program Files` 那类程序（MSI / 带卸载器的），光靠 winget 重装可能装不回原样、原路径、原版本。
所以补上第三条路：**把程序目录本身也备份，还原时按原安装路径放回**。

| 环节 | 做法 |
|------|------|
| 识别 | 扫三处 Uninstall 注册表（HKLM 64/32 + HKCU），要求 `InstallLocation` 存在、非系统目录、`Publisher` 非微软、名字不命中黑名单 |
| **只备份用户装的** | 三重保险：① **增量判定**（开机基线里的镜像自带程序一律跳过）② **静态黑名单** `imageBlockPaths`（VS / Android SDK / hostedtoolcache / AzureCLI …）③ **体积上限** |
| 备份 | 程序目录镜像到 `<Stage>\programs\<盘符>\<路径>`，并**逐程序 `reg export` 它的 Uninstall 键** |
| 还原 | 程序实体落 **`D:\cloudrdp-sys\programs\<镜像>`**，在原路径（如 `C:\Program Files\Foo`）建 **junction** 指过去；随后导入 Uninstall 键 |
| 兜底 | 因为 Uninstall 键回来了，`winget` 会判定「已安装」而**跳过重装**，不会装两份 |

**体积必须克制**：139 WebDAV 实测约 **0.45 MB/s**（1 GB ≈ 37 分钟），所以默认
`programs.maxMBPerApp = 1024`、`programs.maxTotalMB = 2048`。超限的会**在日志里列名告警**，不会静默丢。
想放宽就改这两个值。

> 首次推送新程序集较慢（要传字节）；之后每次 `rclone sync` 只传**变化的部分**
> （robocopy 保留时间戳，远端比对 size+mtime 后跳过），所以后续开机很快。

- 开关：`programs.enabled` / `preferJunction` / `maxMBPerApp` / `maxTotalMB` / `blocklist` / `excludePaths`
- 默认只在**收尾全量**快照里采集（`programs.captureInQuick=false`，避免每 60 分钟重复备份）
- 不想用 junction（直接还原到 C 盘原路径）：`programs.preferJunction = false`
- 开机基线由 `pre-restore.ps1` 的**第 0 阶段**在任何还原动作之前记录；上次备份过的程序清单也会带过来，
  保证「跨运行持久」——已还原的程序下次关机时仍会被备份，不会因为「基线里有」而被漏掉

---

## 五、目录结构

```
cloud-rdp/
├── .github/workflows/windows-rdp.yml   # 主工作流（16 步，见下表）
└── scripts/
    ├── setup-rclone.ps1                # 安装并配置 rclone
    ├── setup-alist.ps1                 # 部署 AList，挂载 139 云盘
    ├── migrate-139.ps1                 # 【新】139 老路径 → AI文件库（一次性、幂等、只 copy）
    ├── sync-down.ps1                   # 139 → D:\a\cloud-rdp（数据恢复，含排除仓库）
    ├── sync-up.ps1                     # D:\a\cloud-rdp → 139（数据备份，含排除仓库）
    ├── pre-restore.ps1                 # 预还原：记录程序基线→拉取→校验→规划→准备→回滚记录→preCommands→驱动还原
    ├── snapshot-config.json            # 整机快照清单（改这里调整备份/还原范围 + C 盘阈值）
    ├── portable-lib.ps1                # 可移动程序：识别 / 搬运 / 按原路径还原
    ├── programs-lib.ps1                # 【新】安装型程序：目录级备份 / Uninstall 注册表 / junction 还原
    ├── disk-guard.ps1                  # 【新】C 盘守卫：基线 / 增量限额 / 安全清理 / 状态透出
    ├── backup-snapshot.ps1             # 抓取整机状态 → D:\cloudrdp-sys\_snapshot → 139/AI文件库/_snapshot
    ├── restore-snapshot.ps1            # 还原整机状态（machine / user 两个作用域）
    ├── reinstall-apps.ps1              # winget 后台逐包重装（日志 + 进度 JSON）
    └── quota-report.ps1                # Actions 额度估算与告警
```

工作流 16 步：

| # | 步骤 | 说明 |
|---|------|------|
| 0 | 拉仓库 | `actions/checkout` |
| **0b** | **C 盘守卫：记录基线** | `disk-guard.ps1 -Baseline` |
| 1–2 | 开 RDP / 建账号+数据目录 | 数据目录 `D:\a\cloud-rdp`（**会排除其中的仓库 checkout**） |
| 3–6 | Tailscale / AList 密码 / rclone / 部署 AList | 139 挂载点 `/cloudrdp`；rclone / AList 都装在 `D:\cloudrdp-sys` |
| **7** | **（可选）迁移 139 老路径** | 仅当 `migrate_139=true` |
| **8** | **从 139 拉取数据** | `sync-down.ps1` |
| **9** | **预还原** | `pre-restore.ps1 -Pull`（记录程序基线 → 校验 → 规划 → 回滚记录 → 驱动全量还原） |
| **10** | **后台重装软件** | `reinstall-apps.ps1 -Background`（异步，不阻塞） |
| **10b** | **C 盘守卫：清理 + 报告** | `disk-guard.ps1 -Enforce` |
| **11** | **额度 + 打印连接信息** | 记下 Tailscale IP；含 C/D 盘占用与本次增量 |
| 12 | 保活 | 每 10 分钟同步数据；每 30 分钟 C 盘守卫；每 60 分钟抓整机快照 |
| 13 | 收尾 | `if: always()`：C 盘清理 + 全量同步数据 + 抓整机快照 |

139 云盘内的存放位置：

| 路径 | 内容 |
|------|------|
| `AI文件库/CloudRDP/` | 用户数据（`D:\a\cloud-rdp` 的镜像） |
| `AI文件库/_snapshot/` | 整机快照（文件 / 注册表 / 软件清单 / 设置 / 快捷方式） |

---

## 六、常见问题

| 现象 | 原因 | 解决 |
|------|------|------|
| 第 6 步报「创建 139 存储失败」 | `Authorization` 过期或复制多了 `Basic` | 重新获取 Authorization，只取 `Basic ` 后那段，更新 Secret |
| 第 6 步报驱动不存在 | AList 版本驱动名不同 | 日志会打印可用驱动列表，改 `setup-alist.ps1` 里的 `$driverKey` |
| `sync-down` 退出码非 0 | 首次运行远端为空（正常）/ Authorization 过期 | 首次可忽略；否则更新 Secret |
| C 盘占用显示 80%+ | 那是 runner **镜像自带**的（VS / Android SDK / 工具缓存），开机就有 | 正常。我们守的是「本次增量」，见 ⑦ |
| C 盘增量显示 `OVER` | 有大文件写进了 C 盘，或新程序装到了 C 盘 | 大文件放 `D:\a\cloud-rdp`；新装程序选 D 盘；或调大 `disk.maxIncrementalPercent` |
| 某程序还原后打不开 | 写死了绝对路径 / 需要注册服务 / 体积超上限被跳过 | 看日志里 `跳过：xxx`；调大 `programs.maxMBPerApp`，或设 `programs.preferJunction=false` 直接还原到原路径 |
| 安装型程序备份很慢 | 139 WebDAV 约 0.45 MB/s，首次要传字节 | 正常，首次慢、之后只传变化；用 `programs.maxTotalMB` 控总量 |
| 上传大文件卡住 | 139 走 WebDAV 有 5 分钟超时 | 单文件建议 <500MB；超大文件用 139 官方客户端 |
| 连不上 100.x.x.x | 本地没登录 Tailscale | 本地客户端登录同一账号，`tailscale status` 检查 |
| 会话突然断开 | 6 小时到点，Job 被回收 | 正常，重新 Run workflow |
| 整机还原显示 `PARTIAL` | 个别目录/注册表键还原失败（日志有明细） | 看日志 `[restore]` 行定位；多为该目录不存在或权限问题 |
| 登录后个人配置没回来 | 登录还原任务失败或未触发 | 查「任务计划程序」里的 `CloudRDP-RestoreUser`；日志在首次登录时不可见，可手动跑 `D:\cloudrdp-sys\_snapshot\_tools\restore-snapshot.ps1 -Scope user` |
| 关机前的改动丢了 | Job 被**硬杀**（超时/取消太快），收尾步骤没跑完 | 保活期每 60 分钟会自动抓一次快照，最多丢 1 小时内改动 |
| 快照没上传 | 快照超过 `files.maxTotalMB`（默认 8GB） | 日志会告警并跳过后续目录；调大上限或从清单里删掉大目录 |
| 预检报「`AI文件库` 不存在」 | 139 里还没建这个文件夹（脚本刻意不自动创建） | 在 139 网页根目录下建好「AI文件库」后重跑；或改用「根 ID 法」（见 §4.⑥） |
| 139 上找不到数据 | 还在老路径 `/CloudRDP` | Run workflow 时勾 `migrate_139=true` 迁移一次 |
| 数据目录里混进了仓库文件 | rclone 排除规则没生效（`GITHUB_WORKSPACE` 与数据目录不匹配） | 看日志 `[sync-up] 排除:` 那行；确认里面有 `/cloud-rdp/**` 与 `/.git/**` |
| 可移动程序没被备份 | 被判定为「非可移动」（MSI 安装 / 落在系统目录 / 体积超限 / 命中黑名单） | 日志会打印候选数；要强制纳入可把路径加进 `portable.scanRoots` 或用 `files.dirs` 直接抓 |
| 可移动程序搬走机器变卡 | 用了 `portable.mode: "relocate"`（junction）且程序正被占用 | 改回默认 `copy`；relocate 是高级用法，会临时移动原目录 |
| winget 重装一直没动静 | 后台进程还在跑 / 清单为空（首次运行） | 看 `D:\cloudrdp-sys\_snapshot\_logs\apps-reinstall.log` 与 `apps-status.json`；首次运行无清单属正常 |
| 想跳过自动重装 | —— | Run workflow 时把 `install_apps` 填 `false` |
| `preCommands` 里的命令没生效 | 命令失败被 fail-soft 忽略（不阻断还原） | 看日志 `[pre-restore]   [n] 失败`；命令里建议用绝对路径 |

---

## 七、风险声明

- **非官方用途**：用 GitHub Actions 跑个人云桌面不符合其服务条款，长期使用可能被限流/封号。本仓库默认**私有**以降低暴露面，但**无法保证账号安全**。
- **不要存重要/隐私数据**：数据经 AList 非官方桥接写入 139 云盘，链路不保证稳定与安全。
- **快照含敏感文件**：`.ssh`、`.aws`、`.config`、`.vscode` 等会被同步到 139 云盘。若不愿外传，
  请在 `scripts/snapshot-config.json` 的 `files.dirs` 里删掉对应条目（改完提交即可）。
- **可移动程序会被复制一份**：默认 `copy` 会在数据目录里留副本（占额外磁盘），
  体积上限见 `portable.maxMBPerApp` / `portable.maxTotalMB`；不想用就设 `portable.enabled=false`。
- **数据目录在 `D:\a\cloud-rdp`**：D 盘是 runner 的临时盘，机器销毁即消失 —— 持久化完全依赖 139，
  所以**务必确认每次运行日志里「数据恢复 / 整机还原」不是 `FAILED`**。
- **自动重装会跑很久**：402 个包可能几十分钟，期间机器可用但会占带宽/CPU；不想要就把 `install_apps` 填 `false`。
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
