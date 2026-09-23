# cloud-rdp

用 **GitHub Actions（私有仓库）** 跑一台临时 Windows 云主机，通过 **Tailscale** 组网，本地 `mstsc` 直连；
数据用 **rclone + AList** 桥接到 **中国移动云盘（139）**，实现跨会话持久化。

> ⚠️ 本方案不符合 GitHub Actions 官方用途定义（CI/CD），属于技术玩法。请阅读文末[风险声明](#风险声明)。

---

## 一、能力与限制

| 项 | 说明 |
|----|------|
| 配置 | 约 4 核 16G（`windows-latest`，实际以 runner 为准） |
| 单次时长 | **单个 Job 最长 6 小时**（GitHub 硬上限，无法突破）；想更久用**接力**：填 `relay_minutes=2880` 可自动续到 48 小时（见第四节） |
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

## 三、配置账号与 Secret（截图级）

进入仓库 → **Settings** → 左侧 **Secrets and variables** → **Actions** → **New repository secret**。

> ⚠️ **仓库必须是公开的**（见第六节额度说明）—— 公开后 Actions 日志全球可见。

### 1. RDP 账号密码（写死在 workflow，日志明文打印）

打开 `.github/workflows/windows-rdp.yml`，改顶部 `env:` 两行即可：

- `RDP_USERNAME`：默认 `a`
- `RDP_PASSWORD`：默认 `"a"`（改时**务必保留两侧引号**）

这两个值**刻意写死**，原因是：

- **日志里要明文打印**（第 0d 步「打印连接信息」）—— 一眼看到、直接拿去连，不用翻 Secret、不用等邮件。
- GitHub 会把 **Secret 值自动打码成 `***`**，所以「想明文打印」与「用 Secret 存」**互斥**。

> ⚠️ **代价**：仓库是公开的，这两个值会**永久留在 git 历史与公开日志**里，无法撤回。
> 机器只能经 Tailscale 内网访问 —— **tailnet 才是真正的安全边界**，密码只当第二道门。
> 想更稳就把密码换成强密码（代价是每次得复制粘贴，不能再手敲 `a`）。

### 2. `TAILSCALE_AUTHKEY`

1. Tailscale 后台 → 左侧 **Settings** → **Keys** → **Generate auth key…**
2. 勾选 **Reusable**、**Ephemeral**，Expiration 选 **90 days**
3. 复制生成的 `tskey-auth-...`，填入 Secret

### 3. 邮箱投递（可选，默认关闭）

把「Tailscale IP + 账号 + 密码」**同时**发一份到你邮箱。**不配也能跑** —— 脚本会打印「跳过发信」并正常继续。

| Secret | 说明 | 示例 |
|--------|------|------|
| `MAIL_TO` | 收件邮箱（必填；多个用 `,` 分隔） | `you@qq.com` |
| `MAIL_USER` | 发件邮箱账号 | `sender@qq.com` |
| `MAIL_PASS` | 发件邮箱的 **SMTP 授权码**（不是登录密码） | `abcdwxyzabcdwxyz` |
| `MAIL_SMTP_HOST` | SMTP 服务器 | `smtp.qq.com` |
| `MAIL_SMTP_PORT` | 端口，默认 `465` | `465` |
| `MAIL_FROM` | 发件人地址，默认 = `MAIL_USER` | 可留空 |
| `MAIL_FROM_NAME` | 发件人显示名，默认 `CloudRDP` | 可留空 |
| `MAIL_CC` | 抄送 | 可留空 |

> - **QQ 邮箱**：`smtp.qq.com` + `465`（设置 → 账户 → 开启 SMTP 服务 → 拿**授权码**）
> - **163 邮箱**：`smtp.163.com` + `465`
> - 端口会自动推断加密方式：`465`=隐式 SSL、`587`=STARTTLS、`25`=明文；也可用 `MAIL_SECURITY` 强制。
> - **不配这组 Secret 也能跑**：脚本会打印「跳过发信」并正常继续。密码照常在第 0d 步的日志里明文打印。

### 4. `ALIST_139_AUTHORIZATION`（关键，约 15 天过期）

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

把本仓库推送到你的**公开** GitHub 仓库（命令见文末）。

### 2. 启动云主机

**① 定时自动（默认开启）** —— workflow 内置两个 cron，北京时间每天自动开两次：

| 场次 | 北京时间开机 | UTC cron | 自动关机 |
|------|--------------|----------|----------|
| 早场 | **08:30** | `30 0 * * *` | 11:30 |
| 午场 | **13:30** | `30 5 * * *` | 17:30 |

到窗口结束时间会**自动停止**并做最后一次全量同步（不会两场重叠）。

**② 手动** —— 仓库顶部 → **Actions** → 左侧 **Windows Cloud RDP** → **Run workflow**（手动触发跑满 5 小时 50 分）。

**启动后约 2~3 分钟**，展开 **`0d. 打印连接信息（可立即连接）`** 步骤记下 **Tailscale IP** —— 此刻就能连进来。

> ⏱️ **剩下的是后台初始化**：C 盘瘦身 → 数据/桌面恢复 → 中文环境 → 软件重装，通常再要 **30~60 分钟**
> （取决于 139 云盘速度，实测约 0.45 MB/s）。
> **等到日志出现 `>>> ENV READY —— 环境初始化完成 <<<`（第 13 步）**，才代表「满血」环境就绪。
> 提前登录也能用，但数据 / 桌面 / 中文输入法可能还在恢复中。

> 💡 人在 RDP 里看不到 Actions 日志 —— 公共桌面会放一个标记文件：
> 初始化中叫 `_CloudRDP_SETTING_UP.txt`（含 IP / 账号 / 密码），完成后自动改名为 `_CloudRDP_READY.txt`。
> 也可以在 https://login.tailscale.com/admin/machines 看到 `github-rdp-server*` 设备。

> ✅ **本仓库用公开仓库跑** —— 公开仓库的 Actions 额度**免费且无限**，这是唯一能长期每天跑的办法。
> 私有仓库只有 **2000 分钟/月**，一次满时长 run ≈ **350 分钟** → 整月仅 **5~6 次**，
> 超额后 Actions **直接停摆且不报错**（表现为：手动触发 7 秒失败，注解写
> `recent account payments have failed or your spending limit needs to be increased`）。
>
> ⚠️ **公开的代价**：Actions 日志全球可见，所以**绝不能把密码写进仓库** ——
> 见第三节：RDP 密码走 Secret（日志自动打码成 `***`），连接信息靠**邮件 + 公共桌面标记文件**交付。
> 日志里可见的只有 Tailscale 设备名（`github-rdp-server*`）与内网 IP，而它们只在你的 tailnet 内可达。
>
> 私有仓库的额度实测口径（保留，用来说明「为什么必须公开」）：
> 官方 Billing API 显示额度**按原始分钟抵扣、不乘 Windows 2× 倍率**
> （实测：某月 1858 分钟 Windows 用量 → `grossAmount` $18.58、`netAmount` **$0.00**，全额抵扣）。
> 额度耗尽后 Actions 直接停摆、**不会报错**，直到次月 1 号重置。

> 💡 **内置额度告警**：每次开机时 step 12 会算出本月已用额度，并在 step 13 的汇总里显示剩余 ——
> **≤50% 变黄、≤20% 变红**。
> - **首选数据源**：官方 Billing API `GET /users/{owner}/settings/billing/usage?year=&month=`
>   → 账号级准确数字，**需要 `user` scope 的令牌**（存于 Secret `GH_BILLING_TOKEN`）
> - **回退数据源**：本仓库 run 历史求和（`GITHUB_TOKEN` + `actions: read`）
>   → 只算本仓库，会**严重低估**（实测：真实 1858 分钟，回退只算出 181）
> - 脚本：`scripts/quota-report.ps1`，输出的 `QUOTA_SOURCE` 会显示实际用了哪个源

### 3. 本地连接

1. **前提**：本地电脑已安装 Tailscale 并登录**同一账号**
2. `Win + R` → `mstsc` → 计算机填 **Tailscale IP** → 连接
3. 用户名 `a`，密码 `a` —— 两个值都在 **第 0d 步「打印连接信息」的日志里明文打印**，
   直接复制即可（也可从公共桌面 `_CloudRDP_*.txt` 取）
4. 证书警告点「是/继续」

### 4. 数据与整机状态持久化

云主机是**一次性**的：每次开机都是全新 Windows 镜像。所以「上次关机前的样子」必须靠
**自己抓取 + 自己还原**。本项目用两条独立管线覆盖：

#### ① 数据管线（`D:\a\cloud-rdp`，高频）

- 云主机里用 **`D:\a\cloud-rdp`** 存数据（**公共桌面已放 `CloudData` 快捷方式**，双击即达）
- **开机自动恢复**：每次启动自动把 139 云盘的 `/AI文件库/CloudRDP` 拉回 `D:\a\cloud-rdp`
- 运行中每 10 分钟推送到 139 云盘；关闭会话后还会做一次全量推送
- 恢复结果会显示在 **「13. 环境就绪汇总（ENV READY）」** 步骤里，也会写进机器上的
  `D:\cloudrdp-sys\_state\restore-status.json`（工作台「机器运行实况」表的**「恢复」列**直接读它）：

  | 状态 | 含义 |
  |------|------|
  | `OK` | 恢复成功（日志打印文件数 / 大小） |
  | `EMPTY` | **确认**远端还没有数据（139 上父目录可列、里面确实没有该目录 —— 首次运行正常） |
  | `TRANSIENT` | 139 暂时不可达（DNS/网络抖动、5xx）—— **不是**「远端为空」；本次不拉取，保活循环每 10 分钟自动重试 |
  | `FAILED` | 恢复失败 —— 多半是 139 Authorization 过期；`D:\a\cloud-rdp` 是空的，**别在上面存重要东西** |

  > **为什么区分 `EMPTY` 与 `TRANSIENT`（acc-1 事故的根因）**：rclone 对「目录不存在」返回码
  > 3/4，但对「DNS 解析失败 / 后端 404」**也**返回 3。旧版 `sync-down.ps1` 只看退出码，于是一次
  > **5 秒 DNS 抖动**就被误判成「远端为空」，机器空着手起来、界面却显示「已同步」。现在统一由
  > 共享库 `scripts/remote-lib.ps1` 判定（`OK`/`EMPTY`/`TRANSIENT`/`AUTH`），铁律是
  > **先探后拉**：先把 139 根目录列出来，再逐级下探；探不通一律 `TRANSIENT`，**绝不写本地、绝不写远端**。

- 恢复失败时会在 `D:\a\cloud-rdp` 留一个 `_RESTORE_FAILED.txt` 标记，并**红色高亮**警告
- 恢复失败**不会**挡住 RDP 启动（脚本永远返回 0），保证机器始终可用
- **保活循环自愈**：每 10 分钟读一次 `restore-status.json`，只要是 `TRANSIENT`/`FAILED`/`PENDING`
  就自动 `sync-down.ps1 -Repull` 重拉；快照没还原成功前**不会推送**（避免用空壳覆盖 139 上的好快照）

#### ② 整机快照管线（文件 / 注册表 / 设置，低频）

覆盖 `D:\a\cloud-rdp` 之外的一切「关机前的样子」，存到 139 的 **`/AI文件库/_snapshot`**（与 `/AI文件库/CloudRDP` 分开）。

**抓取时机**：开机后基线、保活期间**每 60 分钟**、**关机前全量**（`if: always()`，取消也会跑）。

**推送后自校验**：`rclone sync` 成功后会回读远端（`rclone size`），日志打印
`远端校验：N 个文件 / X MB（本地 M 个 / Y MB）` 并输出 `SNAPSHOT_VERIFY` ——
这是「快照确实落到 139」的日志证据，不用另外登录云盘确认。

**抓什么**（全部可在 `scripts/snapshot-config.json` 里改，无需改脚本）：

| 类别 | 内容 |
|------|------|
| 文件 | `C:\scripts`、`C:\apps`、用户 `Desktop/Documents/Downloads/Pictures/Videos/Music/Favorites`、**公共桌面 `C:\Users\Public\Desktop`**、`AppData\Roaming\...\Start Menu`、`.ssh`、`.aws`、`.config`、`.vscode\extensions`、`.gitconfig`、**WorkBuddy 全套**（`.workbuddy` = 用户数据/缓存/二进制、`.workbuddy-ai` = 旧路径（兼容老快照）、`AppData\Local\Programs\WorkBuddy` = 安装目录、`AppData\Local\WorkBuddy`、`AppData\Roaming\WorkBuddy`）等 |
| Edge 浏览器 | `%LOCALAPPDATA%\Microsoft\Edge\User Data`（**浏览记录 `History` / 书签 `Bookmarks` / 全部设置 `Preferences`（含下载位置）/ `Web Data` / `Login Data` 本地已存密码 / `Local State` / cookie / 图标**；缓存类目录已排除，见 ⑨） |
| 程序关联数据 | 按程序名/发布商匹配的 `%APPDATA%`、`%LOCALAPPDATA%`、`%LOCALAPPDATA%\Programs`、`%PROGRAMDATA%` 一级子目录（见 ⑨） |
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
| `machine` | 开机第 8 步 | `runneradmin` | 拉快照、还原机器级文件、导入机器注册表、恢复时区/电源/关防火墙、还原公共桌面、**预创建用户配置文件并把个人桌面/文档/HKCU 直接还原到位**，再注册登录任务作兜底 |
| `user` | RDP 用户**首次登录**时 | `a` | 兜底重放个人目录文件、HKCU、个人快捷方式与壁纸；**成功才自注销，失败保留任务下次重试**并在公共桌面写标记 |

> **开机即预还原**：先用 `Start-Process -Credential` 让 Windows 真正创建并注册该用户的配置文件
> （`CreateProcessWithLogonW` 会 `LoadUserProfile`），再 `reg load` 它的 `NTUSER.DAT` 导入 HKCU
> （把 `__RDPUSER__` 换成 `HKEY_USERS\_Restore`），最后 robocopy 个人文件。
> 这样**一开机桌面就是满的**，不用等首次登录。失败会自动回退到登录任务，行为与旧版一致。
>
> HKCU 导出时会把 SID 归一化成 `__RDPUSER__` 占位符，换机后 SID 变了也能正确导入。

**还原状态**显示在同一处连接信息里：`OK` / `PARTIAL` / `EMPTY` / `FAILED`。

**已知边界**（做不到的，别指望）：

- 需要**授权码/硬件绑定**的商业软件，激活状态无法复刻
- Windows 更新状态、驱动、运行中的进程状态不涉及
- **Edge cookie / 密码跨机大概率解不开**（DPAPI 绑「用户+本机」）：历史、书签、偏好、`Web Data`、图标能回来，
  但 cookie 与已保存密码需靠 **Edge 账号同步**恢复登录态。另外 cookie 属敏感凭证，会被上传到 139
- **体积不设上限**（`files.maxTotalMB` / `programs.maxMBPerApp` / `programs.maxTotalMB` 全为 `0 = 不限`）。
  139 实测约 0.45 MB/s：10 GB 约 6.3 小时，可能超出 6 小时 job 上限。推送前会估算 `SNAPSHOT_ETA_MIN`，
  并按剩余时间给 rclone 设 `--max-duration`；大目录用 `rclone copy`（**可断点续传、被中断也不会毁远端**）
- Chrome 的 profile 仍未抓（只有 Edge）
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

开机第 8 步跑 `scripts/pre-restore.ps1 -Pull`，负责「把**关机前的完整状态**校验清楚、准备就绪，再驱动全量还原」：

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
- **用 `Start-Process` 拉起后台进程后立即返回** → **`0d` 的抢先版连接信息秒出**，你马上就能连 RDP，装包在后台继续
- 日志 `D:\cloudrdp-sys\_snapshot\_logs\apps-reinstall.log`；进度 `D:\cloudrdp-sys\_snapshot\_logs\apps-status.json`
- 临时关闭：`Run workflow` 时把 `install_apps` 填 `false`，或改 `restore.installApps`
- 限量试跑：`restore.maxPackages`（0 = 不限）
- **收尾还会做「用户数据完整性」校验 + 补漏**（`scripts/userdata-lib.ps1`，与第 8 步同源、口径唯一）：
  - 逐目标核对 **Edge**（`History` 浏览记录 / `Login Data` 本地已存密码 / `Preferences` 全部设置含下载位置 / `Bookmarks` / `Web Data` / `Local State`）与 **WorkBuddy**（`.workbuddy` 用户数据+缓存、`.workbuddy-ai` 旧路径、安装目录、`AppData\Local\WorkBuddy`、`AppData\Roaming\WorkBuddy`）
  - 缺什么补什么：robocopy **只补不删**（不动你在机器上新增的文件）、幂等；补漏前先关闭占用程序，保证 SQLite(WAL)/LevelDB 一致
  - 结论写 `apps-status.json` 的 `userData` 字段，并透出 `USERDATA_RESTORE` / `USERDATA_RESTORE_DETAIL` / `EDGE_RESTORE` / `WBAI_RESTORE`（第 13 步 ENV READY 会打印）
  - 目标清单在 `snapshot-config.json` 的 `restore.userDataTargets`；`restore.userData: false` 整体关闭；只重装不校验用 `-SkipUserData`

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
- **一次性迁移**：`Run workflow` 时把 `migrate_139` 填 `true`，第 6 步会 `rclone copy`（**不 move**）把老数据搬到新位置；
  幂等守卫：仅当「新路径为空 且 老路径非空」才执行。老数据原样保留，可随时切回
- **备选「根 ID 法」**：若不想让远端路径出现中文，可把 Secret/环境变量 `ALIST_139_ROOT_FOLDER_ID` 设为
  「AI文件库」的**文件夹 ID**（139 网页 F12 从请求里取），AList 的 `/cloudrdp` 会直接映射到该文件夹，
  远端路径即回归纯 ASCII（`alist:/cloudrdp/CloudRDP`），脚本原生支持，无需改代码

#### ⑦ C 盘策略：开机瘦身（压到 ≤30%）+ 增量守卫

**硬事实**：GitHub 托管 Windows runner 的 C 盘 **150 GB 里约 120 GB 是镜像自带**的
（Visual Studio 2022 / Android SDK / `hostedtoolcache` / Windows SDK / SQL Server / JDK / 浏览器 …），
**开机就是约 80%**。要让它 ≤30%，只能把这些**用不到的大件删掉**。于是分两手：

**① 开机瘦身（`scripts/slim-image.ps1`，第 1 步）** —— 删镜像大件，约释放 **70 GB**：

| 目标 | 约占用 |
|------|--------|
| `C:\Program Files\Microsoft Visual Studio` | 30–35 GB |
| `C:\Android` | 10–15 GB |
| `C:\hostedtoolcache` | 10–12 GB |
| Windows SDK / MSBuild / MS SQL Server / LLVM / CMake / R / Strawberry / Mercurial / Docker / AWS / AzureCLI | 15–20 GB |
| Chrome / Firefox | ~1.5 GB |

- 模式 `slim.mode`：`auto`（默认，**仅当 C 盘占用 > `targetPercent` 时才瘦身**）/ `always` / `off`
- 手动触发时可用输入 **`slim_image`** 临时覆盖（`auto` / `always` / `off`）
- 只删 `slim.targets` 里**显式列出**的路径，不做任何通配扫描
- **硬保护名单**（写死，配置里写了也不会删）：`C:\Windows`、`C:\Users`、
  `C:\Program Files\WindowsApps`（**winget 在这**）、`C:\Program Files\PowerShell`（**我们自己要跑 pwsh**）、
  Windows Defender、Common Files、IE、`Microsoft\Edge` / `EdgeWebView`（WebView2 依赖）、`C:\actions-runner`，
  以及工作区 / 数据目录 / 系统目录 / 快照暂存 / 程序还原根
- 保护判断同时拦「受保护目录内部」**和**「受保护目录的父目录」—— 所以配置里写 `C:\Program Files\Microsoft`
  这种宽泛父目录会被**直接拒绝**（因为它内含受保护的 Edge）
- 默认**不动**可能被你的程序依赖的运行时：`.NET` / `nodejs` / `Java` / `Eclipse Adoptium`
  （清单里 `enabled: false`，需要时改 `true`）
- 另附：关休眠（回收 `hiberfil.sys`）；可选 `runDismComponentCleanup`（默认关，较慢）
- **无条件删除清单 `slim.alwaysDelete`**（不受 `enabled`/`mode`/`targetPercent` 影响，每次开机都执行）——
  当前含 `C:\Program Files\Unity Hub`。用于清理「用户明确不想要」的程序；仍受硬保护名单约束
- fail-soft：删不掉只告警，**永不返回非 0**

**①-a 真卸载清单 `blockedApps`（第 1 步内，顺序在「清空 MSI 缓存」之前）**

有些程序光删目录不够 —— 还会留下 ARP 卸载项、Windows 服务、`ProgramData` 数据目录，
下次开机照样占空间。所以改成**真卸载**（三级降级，每级都有超时保护）：

| 级别 | 手段 |
|---|---|
| ① | `winget uninstall --id <id> -e --silent --disable-interactivity` |
| ② | ARP 入口：`QuietUninstallString` → `msiexec /x {产品码} /qn /norestart` → Inno `unins000.exe /VERYSILENT …` |
| ③ | 目录兜底：`Remove-BigTree` 清 `paths[]`（含卸载残留与数据目录） |

- 当前清单（`snapshot-config.json` → `blockedApps.entries`）：**Rtools 4.5、Azure Cosmos DB Emulator、
  MongoDB Server / Shell、Strawberry Perl、OpenSSL、Microsoft Azure Service Fabric、Unity Hub、MySQL Server**
- 安全约束：`SystemComponent=1` 的 ARP 条目**一律跳过**；只处理配置里显式列出的条目；不匹配则不动
- 卸载前先停该程序的服务/进程（`services` / `processes`）；整体 20 分钟预算，超预算的剩余项交给目录兜底
- **顺序硬约束**：卸载必须排在「清空 `C:\Windows\Installer`」**之前** —— MSI 卸载依赖缓存里的安装包
- **防回潮（三处，缺一不可）**：① `reinstall-apps.ps1` 从重装清单剔除；② `backup-snapshot.ps1`
  把它从 `winget-export.json` 里删掉（让快照本身就干净）；③ 其 `paths` 并入 `programs.excludePaths`
  （永不备份 / 永不还原）+ `match` 并入 `programs.blocklist`
- 透出 `SLIM_UNINSTALL_OK` / `SLIM_UNINSTALL_FAILED`

**①-b 清空型目标 `slim.purgeContents`（只清内容、保留目录本身）**

`C:\Windows\Installer`（MSI 缓存）实测 **6.7 GB**，但它位于硬保护名单内部（`C:\Windows`），
走 `targets` 必被拒 —— 所以单开一条通道：

| 目标 | 说明 |
|---|---|
| `C:\Windows\Installer` | MSI 缓存；**清空内容、保留目录本身**（Installer 服务预期它存在） |
| `C:\Config.Msi` | MSI 安装事务残留目录（多数时候为空） |

- 独立守卫 `Test-PurgeAllowed`：**绝对路径 + 非盘根 + 不得是硬保护名单里的目录本身**；
  只清配置里显式列出的项，不做通配扫描；**从不删目录本身**
- 实现：`robocopy <空目录> <目标> /MIR`（退出码 <8 视为成功），失败再逐子项兜底
- 代价：本机 MSI 程序的**卸载/修复**会失效（一次性机器可接受）；需要时把该项 `enabled` 改 `false`
- 仅在**瘦身实际执行**时生效（`mode=off` 或 `auto` 且未超阈值则整段跳过）
- 透出 `SLIM_PURGED_DIRS` / `SLIM_PURGED_GB`

**② 增量守卫（`scripts/disk-guard.ps1`，第 0c / 10b / 保活每 30 分钟 / 收尾）** —— 瘦身后继续守住「我们产生的增量」：

```
增量 = 当前 C: 已用 − 开机基线已用   ≤   基线可用空间 × 30%
```

> 顺序很关键：**先瘦身（0b）再记基线（0c）** —— 基线反映瘦身后的真实起点，
> 可用空间从约 31 GB 变成约 105 GB，增量上限也随之从 9.3 GB 变成约 31 GB。

其余措施：产物全落 D 盘（数据 / rclone / AList / 快照暂存 / 程序实体）；超限时安全清理临时文件、
Windows 更新缓存、安装包残留。

连接信息里会显示：

```
  开机瘦身     : OK   释放 69.8 GB（删除 24 项镜像大件，保护 0 项）
  C 盘占用     : 29.4%  (44.1 / 150.1 GB)   本次增量 12 MB / 上限 31452 MB
  D 盘可用     : 146.9 GB  (数据 / 快照 / 程序实体都在 D 盘)
```

- 状态：`SLIM_STATUS` = `OK` / `PARTIAL` / `SKIPPED` / `DRYRUN`；`DISK_GUARD_STATUS` = `BASELINE` / `OK` / `FIXED` / `OVER`
- 阈值：`snapshot-config.json` 的 `slim.targetPercent`、`disk.maxIncrementalPercent`
- 两个脚本都**永不返回非 0**，不会因为磁盘问题挡住 RDP 启动

**③ 关闭 Windows 防火墙** —— runner 镜像（windows-2025）现在**默认开启**防火墙，会拦掉 SMB(445)、AList(5244) 等。
现在三层处理：第 0a 步 `Set-NetFirewallProfile -All -Enabled False` 关闭；`system.firewall=false`
不再导出/导入 `.wfw` 整策略（**避免它把防火墙改回开启**）；还原流程在系统设置之后**无条件再关一次**。
> 只关 Tailscale 内网可达性，机器没有公网 IP，暴露面可控。

#### ⑧ 安装型程序复刻：备份目录 + Uninstall 注册表 → junction 还原

装在 `Program Files` 那类程序（MSI / 带卸载器的），光靠 winget 重装可能装不回原样、原路径、原版本。
所以补上第三条路：**把程序目录本身也备份，还原时按原安装路径放回**。

| 环节 | 做法 |
|------|------|
| 识别 | 扫三处 Uninstall 注册表（HKLM 64/32 + HKCU），要求 `InstallLocation` 存在、非系统目录、`Publisher` 非微软、名字不命中黑名单；**缺失时从 `DisplayIcon`/`UninstallString` 推断**（见 ⑪） |
| **只备份用户装的** | 三重保险：① **增量判定**（开机基线里的镜像自带程序一律跳过）② **静态黑名单** `imageBlockPaths`（VS / Android SDK / hostedtoolcache / AzureCLI …）③ **体积上限** |
| 备份 | 程序目录镜像到 `<Stage>\programs\<盘符>\<路径>`，并**逐程序 `reg export` 它的 Uninstall 键** |
| 还原 | 程序实体落 **`D:\cloudrdp-sys\programs\<镜像>`**，在原路径（如 `C:\Program Files\Foo`）建 **junction** 指过去；随后导入 Uninstall 键 |
| 兜底 | 因为 Uninstall 键回来了，`winget` 会判定「已安装」而**跳过重装**，不会装两份 |

**体积不设上限**（按需求）：`programs.maxMBPerApp = 0`、`programs.maxTotalMB = 0`（`0 = 不限`）。

> 139 WebDAV 实测约 **0.45 MB/s**（1 GB ≈ 37 分钟，10 GB ≈ 6.3 小时）。因为不设上限，
> 推送前会估算 `SNAPSHOT_ETA_MIN`，并按「job 预算 − 已耗时 − 15 分钟」给 rclone 设 `--max-duration`；
> **大目录（`files` / `programs`）用 `rclone copy`** —— 只增不删、可断点续传，被中断也不会毁远端，
> 下次开机接着传。元数据小树（manifest/registry/shortcuts/system/apps）仍用 `sync`（排除大目录）。

- 开关：`programs.enabled` / `preferJunction` / `maxMBPerApp` / `maxTotalMB` / `blocklist` / `excludePaths` / `dataGlobs`
- 默认只在**收尾全量**快照里采集（`programs.captureInQuick=false`，避免每 60 分钟重复备份）
- 不想用 junction（直接还原到 C 盘原路径）：`programs.preferJunction = false`

#### ⑨ 程序关联数据 + 文件关联（浏览器数据也在这）

光有程序目录不够 —— 程序的配置/账号/数据库通常在别处。所以补齐：

| 类别 | 做法 |
|------|------|
| **AppData / ProgramData** | 由 `DisplayName`（去版本号）+ `Publisher`（非微软）生成候选名，在 `%APPDATA%`、`%LOCALAPPDATA%`、`%LOCALAPPDATA%\Programs`、`%PROGRAMDATA%` 下**只匹配一级子目录**；发布商目录下再做二级匹配。可用 `programs.dataGlobs` 显式补充 |
| **绝不遍历整个 LocalAppData** | 硬排除 `Microsoft` / `Packages` / `Temp` / `Programs` 根；缓存目录继续走 `files.excludeDirNames` |
| **文件关联 / COM** | 只导出**命中被备份程序 installLocation** 的 ProgID/CLSID（读顶层键默认值与 `shell\open\command` 做子串匹配），**绝不导整棵 HKCR**；可用 `registry.hkcrProgIds` 手动补 |
| **Edge 数据** | `files.dirs` 里加了 `%LOCALAPPDATA%\Microsoft\Edge\User Data`，并排除 `Service Worker` / `IndexedDB` / `File System` / `ShaderCache` / `Media Cache` / `Crashpad` 等缓存目录 |

- 开关：`programs.dataGlobs`、`registry.hkcr`
- **不做**：服务（`HKLM\SYSTEM\...\Services`）与计划任务（`System32\Tasks`）—— 按需求排除

> ⚠️ Edge 的 cookie / 密码由 **DPAPI**（绑「用户+本机」）加密，跨机后 SID 与机器密钥都不同 → **解不开**。
> 历史 / 书签 / 偏好 / `Web Data` 能正常回来。要恢复登录态请用 Edge 账号同步。
- 开机基线由 `pre-restore.ps1` 的**第 0 阶段**在任何还原动作之前记录；上次备份过的程序清单也会带过来，
  保证「跨运行持久」——已还原的程序下次关机时仍会被备份，不会因为「基线里有」而被漏掉

#### ⑩ 中文环境：简体中文 + 微软拼音输入法（登录前生效）

runner 镜像默认 **en-US**，RDP 用户 a 首次登录是纯英文界面且**没有中文输入法**。
`scripts/setup-chinese.ps1` 在**瘦身之前**（第 0f 步）就把环境配好 —— 越早启动，
语言包越有时间在后面的瘦身 / 拉数据 / 还原（约 40 分钟）里悄悄装完：

| 层级 | 做什么 |
|------|--------|
| **语言包** | `Install-Language zh-Hans-CN`（LanguagePackManagement 模块），失败回退 `Add-WindowsCapability`。**交给计划任务在后台装**（约 30~43 分钟），不阻塞开机 |
| **机器级（HKLM）** | `Set-WinSystemLocale zh-CN` + `Set-WinUILanguageOverride` + `Set-WinDefaultInputMethodOverride`（微软拼音）+ `Set-WinHomeLocation`（中国） |
| **用户级（a 的 HKCU）** | 写「语言列表 `zh-Hans-CN` + `en-US`」+ **微软拼音 TIP** + `Keyboard Layout\Preload`（`1=00000804` 中文、`2=00000409` 美式键盘）。登录后即带中文输入法，`Win+Space` / `Ctrl+Space` 切换 |

> **为什么直接写注册表**：`Set-WinUserLanguageList` 只作用于「当前用户」，而脚本以 `runneradmin` 身份运行。
> 所以先 `reg load` 用户 a 的 `NTUSER.DAT`（复用预还原那套机制），按一台真实中文 Windows 的结构写入，
> 卸载后再尝试用 `Start-Process -Credential` 在该用户会话里跑一次 `Set-WinUserLanguageList` 做增强（失败不影响）。
> 用户级语言键在 0f 步先写一遍；第 8 步「预还原」会导入 `HKCU-Software.reg` 把它覆盖掉，
> 所以第 **8b** 步还要再补写一次（幂等、秒级）。

##### 为什么语言包要「转计划任务」+「状态分段落盘」（2026-09-23 复盘）

`0f` 步曾**每次运行都超时**（run `35813312970`：`03:12:41` 起 → `03:18:41` 被 `timeout-minutes: 6` 杀掉，
正好 360s），Actions 里看着就是「中文每次都设置失败」。三个叠加的坑：

| # | 问题 | 现在怎么修 |
|---|------|-----------|
| ① | **超时预算算错**：脚本里「同步等语言包」写死 300s，加上系统 locale 2s + 用户 hive 33s + 增强步 ≥19s ≈ 360s，必然顶到 step 超时 | 同步等待挪到**最后**且默认降到 **90s**；`0f` 步 `timeout-minutes` 提到 **8** 作纯保险（脚本正常 100~150s 就返回） |
| ② | **「超时转后台」根本没生效**：GitHub 结束/超时一个 step 时会杀掉该 step 的**整棵进程树**，`Start-Process` 起的「后台」子进程跟 step 同树，一起被 kill —— 语言包**从来没装成功过**（日志里只有 `TIMEOUT_BACKGROUND`，从没出现「语言包安装结束」） | 改挂**计划任务**（`Register-ScheduledTask` + SYSTEM 身份），由 Task Scheduler 服务拉起，不在 step 进程树里，真正活到开机流程之后；`Start-Process` 仅作兜底 |
| ③ | **状态只在脚本末尾写一次**：被 kill 后 `CHINESE_STATUS` 等一个都没透出，ENV READY 里「中文环境」整行消失 | 状态**分段落盘**（`GITHUB_ENV` + `_state\chinese-status.json`），任何时刻被 kill 都留得下一份自洽状态 |

配套：

- **`12b` 步**（ENV READY 之前）跑 `setup-chinese.ps1 -CheckOnly` 补核对一次；**保活循环**每 10 分钟也补查一次 ——
  后台装完了就把 `CHINESE_LANGPACK` / `CHINESE_STATUS` 刷成真实结果（`PRESENT`），并清掉计划任务
- **`-UserHiveOnly` 不抹状态**：第 8b 步会**沿用**上一步的语言包 / 系统 locale 状态，
  不再把它们写成 `SKIPPED`（否则 ENV READY 会误报「没装」，而实际是「正在后台装」）
- 两个 `Start-Process -Credential` 调用都加了 **`Wait-Process -Timeout 90`** —— 老代码裸用 `-Wait`，
  一旦凭证 / 二次登录服务有问题就会永久挂住开机
- 状态行：`中文环境 : OK   (语言包 OK / 系统 OK / 用户 OK)`，
  透出 `CHINESE_STATUS` / `CHINESE_LANGPACK` / `CHINESE_SYSTEMLOCALE` / `CHINESE_USERHIVE`；
  语言包日志在 `_state\langpack.log`
- 开关：`snapshot-config.json` 的 `chinese.enabled` / `installLanguagePack`；手动触发可用输入 **`chinese`** 填 `off` 跳过
- fail-soft：**永不返回非 0**，语言包下载失败只告警（界面可能仍是英文，但区域 / 键盘布局已改）

#### ⑪ 快捷方式：以线索补抓程序本体 + 还原后校验修复

**现象**：桌面图标双击报「目标驱动器或网络连接不可用」。根因有两条：

1. 快捷方式管线**从不解析 `.lnk`**（备份 `Copy-Item`、还原 `robocopy`，字节级原样搬运）；
2. 程序识别一直依赖 Uninstall 注册表的 `InstallLocation` —— 很多程序（尤其中文软件、用户级安装）**不写这个字段** → 程序本体没被备份 → 还原后快捷方式必然断链。

**主修复：让程序本体跟着回来**

| 手段 | 说明 |
|------|------|
| **推断安装目录** | `InstallLocation` 缺失/不可用时，从 `DisplayIcon`（去 `,0` 索引、去引号）或 `UninstallString`（解析带引号的 exe）取父目录；`MsiExec` / `C:\Windows\Installer` 一律不采纳 |
| **以快捷方式为线索补抓** | 扫公共桌面 / 用户桌面 / 用户开始菜单的 `.lnk`，读 `TargetPath`，用**边界法**推断「程序根目录」：取最长匹配边界（`C:\Program Files`、`…\AppData\Local\Programs`、盘根…）下的**第一级目录** |
| **并入现有程序管线** | 补抓的目录作为 `reason=shortcut` 的合成条目并入 `Get-ProgramsToBackup` → 自动获得 **junction 还原**（实体落 D 盘、原路径照常可用） |
| **跨运行持久** | `pre-restore` 把上次快照的程序**目录清单**写进 `_state/prev-programs.json`，备份侧以 `AlwaysIncludeLocations` 视同 `prev` 继续带上（否则还原回来的程序下次会被当「镜像自带」漏掉） |

**跳过规则**（防御式：宁可不抓，也不误吞）：

| 情形 | 判定 |
|------|------|
| 目标不存在 / 非绝对路径 / UNC / 直接躺在边界下的散落文件 | 跳过并**记名** |
| 目标落在 `SystemRoots` / `ImageBlockPaths` / `programs.excludePaths` / 工作区 / 数据目录 / 系统目录 | 跳过 |
| `.url` | 不参与补抓（校验阶段单独处理） |
| 盘符不在 `shortcuts.captureDrives`（默认仅 `C:`） | 跳过 |
| 单目录 > `captureMaxMBPerTarget` / 累计 > `captureMaxTotalMB` | 跳过并**记名告警**（不静默丢） |
| `_失效快捷方式` 目录内的 `.lnk` | 跳过（避免搬来搬去） |

**兜底：还原后校验与修复**（`Repair-Shortcuts`，机器级 + 用户级各跑一次，
**必须在程序还原之后** —— 否则 junction 还没建，会把好链误判为死链）

- 目标存在 → 不动
- 目标缺失 → 按文件名在**已还原的程序目录**里**唯一定位** → 改写 `TargetPath` / `WorkingDirectory`；定位不到 → 移入同目录下 **`_失效快捷方式\`**（非破坏、可找回）
- `.url`：`http(s)` 一律不动；`file:` 指向缺失本地文件才移入失效文件夹
- **幂等**：失效文件夹内的不再搬；仅在内容变化时改写

- 开关：`shortcuts.captureTargets` / `validateOnRestore` / `parkBroken` / `parkFolder` / `captureDrives` / `captureMaxMBPerTarget` / `captureMaxTotalMB`；`programs.deriveInstallLocation`
- 连接信息会显示：`快捷方式补抓 : 上次快照含 N 个补抓程序（X MB）` 与 `快捷方式校验 : 公共桌面 检查 N / 修复 M / 移入失效 K`
- **完全回滚**：三个开关全关（`captureTargets` / `validateOnRestore` / `deriveInstallLocation`）即退回旧行为

### 5. 改 RDP 账号名（用户名自动迁移）

用户名**被烤进了云端快照路径** —— `%RDPUSERPROFILE%\Desktop` 会镜像成
`_snapshot/files/C/Users/<用户名>/Desktop`，而还原时又会用快照里记录的用户名覆盖当前用户名。
所以直接改账号名会出现「文件还原到旧 profile、以新账号登录看不到」的**静默数据丢失**。

项目内置了幂等迁移脚本 `scripts/rdpuser-migrate.ps1`，由 `pre-restore.ps1` 在
「拉完快照之后、校验/规划/准备之前」自动调用。你只需要改 workflow 顶部两行：

```yaml
env:
  RDP_USERNAME: <新名字>
  RDP_PASSWORD: "<新密码>"
```

下次开机就会自动完成：

| 步骤 | 内容 |
|------|------|
| 改目录 | `files` 与 `programs` 下的 `<盘>\Users\<旧名>` → `...\Users\<新名>` |
| 改 JSON | `manifest.json` 及快照下所有 `*.json` 的每个字符串值（`\Users\旧名` 与 `/Users/旧名` 两种形式）+ `rdpUser` 字段 |
| 改 REG  | 所有 `*.reg`（UTF-16LE）内的字面路径；`HKEY_USERS\__RDPUSER__` 占位符**不动**（它是 SID 归一化的锚点） |

要点：

- **幂等**：快照用户名已等于当前账号 → 直接跳过，不碰任何文件；重复跑无副作用
- **双向自愈**：迁移方向由「当前账号」决定，所以**改回去也会自动迁移回去** —— 改名可逆
- **不阻断开机**：迁移失败只告警并按旧名继续，机器始终可用
- **`.lnk` 不迁移**（二进制）：死链交由还原后的 `Repair-Shortcuts` 修复
- **旧目录保留在 139**：`files`/`programs` 用 `rclone copy` 推送（只增不删），旧的
  `files/C/Users/<旧名>/` 会留在云端当回滚保险；确认新流程没问题后可手动删除
- 结果透出 `SNAPSHOT_USERMIGRATE=OK|SKIPPED|FAILED`，可在日志里核对

---

### 6. 接力续期：6 小时 → 48 小时

**硬事实**：GitHub-hosted runner 的**单个 Job 上限是 6 小时**，这是平台限制，
无论怎么改 workflow 都突破不了。所以「保活 48 小时」不可能在一个 run 内完成，
唯一路径是**接力** —— 本轮快跑满时自动触发下一个 run，新机器起来后从 139 快照恢复。

**怎么用**：手动 Run workflow 时填 `relay_minutes`：

| 填值 | 含义 |
|------|------|
| `0`（默认） | 不接力，跑满单轮约 4.5 小时后机器销毁 |
| `2880` | 接力到累计 **48 小时** |
| 其它 | 任意分钟数，剩余 < 60 分钟时自动停止接力 |

**代价（必须知道）**：

| 项 | 说明 |
|----|------|
| **换机器** | 每轮是一台全新 runner → **Tailscale IP 会变**，需重新到 Actions 日志第 0d 步看新 IP |
| **有空档** | 两轮之间要等 GitHub 调度（通常几分钟） |
| **setup 开销** | 每轮开机 setup 约 65~85 分钟（中文语言包是大头）→ 单轮真正可用约 **4.5 小时** |
| **轮数** | 48 小时 ≈ 接力 **10~11 轮** |
| 数据安全 | 每轮开机自动从快照还原、关机前自动全量备份，桌面/文档/程序都会跟着走 |

**收尾不中断连接**：第 14 步在「保活结束前 15 分钟」用
`scripts/finalize-background.ps1 -Background` 把收尾（C 盘清理 → 全量同步 → 整机快照）
拉到后台，主循环继续 sleep 到 job 硬上限 —— 所以**收尾期间远程连接照常可用**，
收尾也不再占用你的可用窗口。第 15 步只负责等它完成（最多 4 分钟）。

**接力失败怎么办**：`relay-next.ps1` 需要触发 workflow 的权限。默认靠 workflow 顶部的
`permissions: actions: write`。若日志出现 `401/403 Resource not accessible`，
建一个 PAT（勾选 `repo` + `workflow`）存成 Secret `GH_RELAY_TOKEN` 即可 ——
脚本优先用它、回退到 `GITHUB_TOKEN`。接力状态写在 `D:\cloudrdp-sys\_logs\relay-status.json`
与公共桌面 `_CloudRDP_RELAY.txt`。

---

### 7. 账号池：多账号无缝保活（主/备，先搭机制后填）

**目标**：用多个 GitHub 账号组成「账号池」，让机器**一直有 2 台在跑**（互为主备），
一台到寿自动换下一个账号接力 —— 单账号额度耗尽或单机故障都不会断档。

**为什么需要多账号**：单账号的月度 Actions 额度是硬约束。账号池把负载摊到多个账号，
每台机器跑 ~5.5 小时就换账号接力，从而**无缝续命**。

**三个角色**：

| 角色 | 是什么 | 干什么 |
|------|--------|--------|
| **hub 协调器** | `pool-coordinator.yml`（跑在 hub 仓库，每 10 分钟一次） | 巡检各账号 fork 的在跑机 → 补机/轮换 → 用各账号 PAT 触发 `windows-rdp.yml` → 把权威角色写到 `pool-state` 分支 |
| **primary（主）** | 最老的在跑机 | **唯一**写 139（用户数据 + 整机快照） |
| **standby（备）** | 其余在跑机 | 只读热备：开机照常还原、每 10 分钟重拉保持与主一致，**不写 139**；每 5 分钟读 hub 权威状态，主下线后**自升为主**并立即补一次备份 |

**为什么主/备**：两台机器同时写 139 会互相覆盖/冲突。让「最老的在跑机」当主、其余当备，
任一时刻只有一个写者 —— 既有冗余、又无冲突。

**推荐账号数：≥3 个**。2 个也能跑，但轮换时没有空闲账号做重叠替补 → 换机瞬间会有几分钟
空档；3 个及以上才真正「无缝」。

**填充步骤（4 步）**：

1. **每个账号 fork 本仓库**（或独立仓库），保证仓库名一致（默认 `cloud-rdp`）。
   > ⚠️ **fork 里要再配一份 workflow 用的 Secret**：`windows-rdp.yml` 跑在 **fork 自己的**仓库里，
   > 读的是 **fork 自己的** Secret。GitHub 的 Secret **值永不回显、也不能跨仓库复制**，
   > 所以每个 fork 都得**手动**再配一遍：`TAILSCALE_AUTHKEY`、`ALIST_139_AUTHORIZATION`、
   > `GH_RELAY_TOKEN`、`GH_BILLING_TOKEN`、`MAIL_*`（见第三节）。少配一个，机器就起不来或收不到邮件。
2. **给每个账号建一个 PAT**（classic 勾 `repo` + `workflow`，或 fine-grained 给
   `Actions: read/write` + `Contents: read`）。存到 **hub 仓库的 Secret**，推荐一个
   JSON Secret `POOL_TOKENS`（加账号不用改 workflow）：
   ```json
   { "账号1登录名": "ghp_xxx", "账号2登录名": "ghp_yyy", "账号3登录名": "ghp_zzz" }
   ```
   （也支持每账号一个 Secret，名字写进 `pool-config.json` 的 `token_secret`。）
3. **填 `scripts/pool-config.json`**：`hub.owner` 改成你的 hub 账号、`accounts[].owner`
   改成各账号登录名（`enabled` 控制启用）。**密钥绝不写这里**（只放 Secret）。
4. **启用协调器**：`pool-coordinator.yml` 默认每 10 分钟自动跑；也可手动 `Run workflow`
   （勾 `dry_run` 只演练不派发）。它会自动在 hub 仓库建 `pool-state` 分支。

**关键参数（`pool-config.json`）**：

| 字段 | 默认 | 含义 |
|------|------|------|
| `target_machines` | 2 | 目标在跑机数（一直维持这么多） |
| `machine.lifetime_minutes` | 330 | 单机目标寿命（≈5.5h，给 6h 硬上限留收尾余量） |
| `machine.rotate_lead_minutes` | 45 | 到「寿命 − 45min」就派替补，形成重叠交接 |
| `machine.keepalive_minutes` | 330 | 派发时传给机器的保活时长 |
| `standby.repull_minutes` | 10 | 备机重拉间隔 |
| `standby.role_poll_minutes` | 5 | 备机核对权威角色的间隔 |

**降级与兜底（重要）**：

- **hub 停摆**：备机不会盲目抢主（怕双写），主会继续写到自然结束；修复 hub 后自动恢复。
- **只有 2 个账号**：轮换无法重叠 → 换机瞬间有几分钟空档（其余时间仍有 2 台）。
- **某账号 PAT 失效**：协调器跳过该账号并记录，其余账号继续。
- **单机模式**：`pool_role` 留空 = 完全等同历史行为（手动/定时单机跑，向后兼容）。

**与「接力续期」的区别**：接力（上一节）是**同账号同仓库**串起来跑；账号池是**跨账号、
主备冗余、由独立协调器驱动**。两者可独立使用；账号池派发的机器 `relay_minutes=0`。

**相关文件**：`scripts/pool-config.json`（池配置）、`scripts/pool-lib.ps1`（公共库）、
`scripts/pool-coordinator.ps1`（协调器逻辑）、`.github/workflows/pool-coordinator.yml`（定时工作流）。

---

### 8. GitHub 虚拟机管理工作台（本机仪表盘）

把上面这些运维动作收进**一个跑在本机的网页**，不用再翻 GitHub 或敲命令。

```bat
workbench\start.cmd            :: 双击启动，自动开浏览器 http://127.0.0.1:8899
python workbench\selftest.py   :: 离线自测（273 项）
```

| 面板 | 内容 |
| --- | --- |
| **GitHub 账号管理** | 账号清单 + Secret 是否就位 + 当前主/备 + 在跑机；一键启用/停用（写回 `pool-config.json`） |
| **机器运行实况** | Tailscale 在线状态 + 归属账号（读远端 `_state\pool-info.txt`，单机兜底读 runner 工作区 `D:\a\<repo>\<repo>\.git\config`）+ 角色（读 `_state\pool-role.txt`）+ 已运行时长 + 快照新鲜度（读 `_snapshot\manifest.json`） |
| **定时计划运行日志** | `windows-rdp.yml` 与 `pool-coordinator.yml` 的最近 25 次 run（状态/触发方式/用时/SHA/跳日志）；「缩略」只显示最近 5 条 |
| **一键登录机器** | 生成 `.rdp` + `cmdkey` 预存凭据 + 唤起 `mstsc`，免手输密码 |
| **操作台** | 立即巡检协调器 / 干跑 / 派发保活机 / 强制刷新缓存 |

**特点**：纯 Python 标准库零依赖；默认只监听 `127.0.0.1`；GitHub API / Tailscale / SMB 三条链路
互相独立降级；网络按主机择路（直连优先，失败自动回退代理），`pool-state` 读取还有 raw → GitHub API 双通道兜底。

详见 [`workbench/README.md`](workbench/README.md)。

---

---

### 9. 新增账号「一键自动部署」（工作台）

在「GitHub 账号管理」面板点 **＋ 新增**，**必填只有 PAT** —— 贴上**该账号自己的 PAT**
（需 `repo` + `workflow` 权限）；`owner` / `repo` 按需填，**`Secret 名` 可留空**
（新账号通常连仓库都还没建，留空会自动分配一个没被占用的 `POOL_TOKEN_N`），
勾选「新增后自动部署仓库 + 接入账号池」，点「添加」后工作台会自动：

1. **写入配置** —— 把账号写进 `scripts/pool-config.json`（PAT 不写进该文件）。
2. **校验 PAT** —— 调 `GET /user` 确认 PAT 属于所填 `owner`。
3. **留存 PAT** —— 存到本机 `.tools/pool/<owner>.token`（不进 git）。
4. **写 hub Secret** —— 用本机 `gh` 把该 PAT 写进 hub 仓库的 `Secret 名`（协调器据此派发该账号）。
5. **建 fork** —— 仓库不存在则从 hub fork 到该账号名下。
6. **开 Actions** —— fork 默认关 Actions，自动开启并启用各 workflow。
7. **复制机器密钥** —— 在 hub 里跑一个**临时 workflow**，把 hub 的 `TAILSCALE_AUTHKEY` /
   `ALIST_139_AUTHORIZATION` / `GH_RELAY_TOKEN` / `GH_BILLING_TOKEN` / `MAIL_*` 写进 fork
   （GitHub 的 Secret 值**读不回来**，只能这样「借道 hub」复制；跑完自动删除临时 workflow）。
8. **推送配置** —— 把 `pool-config.json` 提交到 hub（协调器读的是 hub 上的这份）。
9. **触发协调器** —— 立刻巡检，随后自动补机 / 主挂备顶。

进度实时显示在面板里的**部署进度**卡片（逐步 ✓/✕ + 北京时间）。任一步失败会标红并给出原因，
修好后重跑一次即可（已成功的步骤是幂等的）。

> **前置条件**：① 本机装了 `gh` CLI（或用仓库自带的 `.tools/bin/gh.exe`）；② 新账号的 PAT 有
> `repo` + `workflow` 权限；③ hub 仓库已配好机器密钥（第三节）。
> **不填 PAT** 时只写配置、不做部署，需你手动完成上面 5~8 步。

### 10. 数据还原可靠性：先探后拉 + fork 自愈（acc-1 事故复盘）

**事故**：账号 `acc-1 · yc1966asgf`（`100.77.250.79`）开机后**没有从 139 云盘拉取数据**，界面却显示
「已同步」。机器空着手起来，随后它自己的 `sync-up.ps1` 还在 139 根目录 `mkdir` 出一个**幽灵
`AI文件库`** 目录（真实的是 `/cloudrdp/AI文件库`），把「空」这个假象固化下来。

**根因**：旧 `sync-down.ps1` 只凭 rclone 退出码 3/4 就判定「远端为空」。但 AList 在 DNS 抖动时会把
WebDAV `PROPFIND` 打成 `404`，rclone **同样**映射成码 3 —— 于是「远端为空」和「网络抖动」无法区分。
日志证据：`03:02` 有 12 次 `lookup personal-kd-njs.yun.139.com: no such host` + 4 次 `404`，
而 `03:02:54` DNS 一恢复，同一个 `PROPFIND` 立刻返回 `207`。

**修复**（本次改动）：

| 改动 | 文件 | 作用 |
|------|------|------|
| 新增共享分类库 | `scripts/remote-lib.ps1` | 统一判定 `OK`/`EMPTY`/`TRANSIENT`/`AUTH`；`Get-RemoteProbe` **先探根目录再逐级下探**；`Set-RestoreStatus` 按 `data`/`snapshot` **分键合并**写状态 |
| 拉取侧 | `scripts/sync-down.ps1` | 先探后拉；`EMPTY` 才留空；`TRANSIENT`/`AUTH` **不拉取**并落状态；新增 `-Repull` 供保活自愈 |
| 快照拉取侧 | `scripts/pre-restore.ps1` | 快照拉取同样分类 + 重试；新增 `-Background`（不阻塞连接）；快照未就绪时写 `snapshot-restore-pending.txt` |
| **防污染守卫** | `scripts/sync-up.ps1`、`scripts/backup-snapshot.ps1` | 守卫 A：139 根目录不可达 → 拒绝 `mkdir`/`copy`（不再留幽灵目录）；守卫 B：本次数据/快照恢复**未成功**（`TRANSIENT`/`FAILED`/`PENDING`）→ **拒绝推送**，避免用空壳覆盖 139 上的好快照（`-Force` 可强制） |
| 工作流自愈 | `.github/workflows/windows-rdp.yml` | ① 新增步骤 **0p**：每次开机从 hub 下载最新 `scripts/` 覆盖（**fork 自愈，永不跑旧逻辑，无需 PAT**）；② 保活循环每 10 分钟自愈重拉；③ ENV READY 打印「数据恢复 / 整机还原」状态 |
| 协调器防多头 | `.github/workflows/pool-coordinator.yml` | fork 里的定时运行直接跳过（只有 hub 才指挥），避免两个机器同时写同一份 `_snapshot` |
| 工作台透出 | `workbench/server.py`、`static/*` | 新增 `/api/overview` 统计 `machines_data_bad`/`machines_snapshot_bad`；机器表新增**「恢复」列**（数据 / 快照两行徽章，`data-tip` 带失败原因） |

**为什么把判定放进共享库**：`sync-down` / `sync-up` / `pre-restore` / `backup-snapshot` 四处都要用同
一套口径。放共享库能保证**判定不漂移** —— 改一处，四处同时生效。

> **运维提醒**：139 根目录下若已存在那个幽灵 `AI文件库`（与 `/cloudrdp/AI文件库` 并存），需**手动删除**；
> 老 fork（如 acc-1）不必再手工同步脚本 —— 步骤 0p 每次开机都会拉 hub 的最新 `scripts/` 覆盖。

## 五、目录结构

```
cloud-rdp/
├── .github/workflows/windows-rdp.yml   # 主工作流（22 步，见下表）
├── workbench/                          # 【新】GitHub 虚拟机管理工作台（本机仪表盘，Python 标准库零依赖）
│   ├── server.py                       #   后端：HTTP 服务 + 全部 API
│   ├── selftest.py                     #   离线自测（273 项）
│   ├── start.cmd                       #   双击启动（※纯 ASCII，见 workbench/README.md）
│   ├── config.example.json             #   配置样例（复制成 config.json）
│   └── static/                         #   前端：index.html / styles.css / app.js
└── scripts/
    ├── setup-rclone.ps1                # 安装并配置 rclone
    ├── setup-alist.ps1                 # 部署 AList，挂载 139 云盘
    ├── migrate-139.ps1                 # 【新】139 老路径 → AI文件库（一次性、幂等、只 copy）
    ├── remote-lib.ps1                  # 【新】远端可达性分类器：OK/EMPTY/TRANSIENT/AUTH + 先探后拉 + 状态落盘
    ├── sync-down.ps1                   # 139 → D:\a\cloud-rdp（数据恢复，含排除仓库）
    ├── sync-up.ps1                     # D:\a\cloud-rdp → 139（数据备份，含排除仓库）
    ├── pre-restore.ps1                 # 预还原：记录程序基线→拉取→校验→规划→准备→回滚记录→preCommands→驱动还原
    ├── snapshot-config.json            # 整机快照清单（改这里调整备份/还原范围 + C 盘阈值）
    ├── portable-lib.ps1                # 可移动程序：识别 / 搬运 / 按原路径还原
    ├── programs-lib.ps1                # 安装型程序：目录级备份 / Uninstall 注册表 / junction 还原 / 关联数据匹配 / HKCR 命中
    ├── disk-guard.ps1                  # C 盘守卫：基线 / 增量限额 / 安全清理 / 状态透出
    ├── slim-image.ps1                  # 【新】开机瘦身：真卸载 blockedApps + 删镜像大件 + 清空 MSI 缓存（约 70 GB+）
    ├── uninstall-apps-lib.ps1          # 【新】卸载库：ARP 扫描 / 停服务 / 三级降级卸载（winget → ARP → 目录兜底）
    ├── regimport-lib.ps1               # 【新】注册表导入容错：识别「部分成功」，只告警不计失败
    ├── setup-chinese.ps1               # 【新】中文环境：装语言包 + 系统 locale + 写 a 的 HKCU（微软拼音）
    ├── rdpuser-migrate.ps1             # 【新】用户名变更迁移：快照目录名 + manifest 字面路径 + .reg 内容（幂等、可反向）
    ├── backup-snapshot.ps1             # 抓取整机状态 → D:\cloudrdp-sys\_snapshot → 139/AI文件库/_snapshot
    ├── restore-snapshot.ps1            # 还原整机状态（machine / user 两个作用域）
    ├── reinstall-apps.ps1              # 第 10 步：winget 后台逐包重装 + Edge/WorkBuddy 用户数据校验补漏
    ├── userdata-lib.ps1                # 【新】用户数据取证/补漏（Edge 已存密码 · WorkBuddy 数据/缓存/安装目录）
    ├── pool-config.json                # 【新】账号池配置（无密钥：hub/账号/PAT-Secret 名）
    ├── pool-lib.ps1                    # 【新】账号池公共库：在跑机发现 / 决策 / 角色 / 状态
    ├── pool-coordinator.ps1            # 【新】hub 协调器：补机 + 轮换 + 发布权威角色
    └── quota-report.ps1                # Actions 额度估算与告警
```

工作流 22 步。**0d 之后就能连**，其余在后台继续跑：

| # | 步骤 | 说明 |
|---|------|------|
| 0 | 拉仓库 | `actions/checkout` |
| **0a** | 记录 job 起点 + 开 RDP + **关防火墙** | 尽早写 `_state\job-start.txt`（供 ETA / 耗时计算） |
| **0b** | 建管理员账号 + 数据目录 + 桌面快捷方式 | 数据目录 `D:\a\cloud-rdp`（**会排除其中的仓库 checkout**） |
| **0c** | 安装并连接 Tailscale | ← **IP 在这里产生**，并记录「可连时刻」 |
| **0c2** | **解析账号池角色** | `pool_role` 留空=单机（等同历史行为）；`primary`=唯一写 139；`standby`=只读热备、主下线自升为主。角色写入 `_state\pool-role.txt` |
| **0d** | ⭐ **打印连接信息（可立即连接）** | **约 2~3 分钟**就能拿到 IP 连进来；账号密码**明文打印**；公共桌面放 `_CloudRDP_SETTING_UP.txt` |
| **0e** | **把连接信息发到邮箱** | `send-connection-mail.ps1`：IP + 账号 + 密码发到你邮箱；**未配置 `MAIL_*` 会自动跳过**，失败也不影响开机。诊断日志 `D:\cloudrdp-sys\_state\mail.log`，结果透出 `MAIL_RESULT` |
| **0f** | **设置中文 + 微软拼音（提前到瘦身之前）** | `setup-chinese.ps1`：`Install-Language` 实测每次 **30~43 分钟**，所以放最前面 + **5 分钟封顶、超时转后台**（`LANGPACK=TIMEOUT_BACKGROUND`）。它能在后面瘦身/拉数据/还原的 ~40 分钟里悄悄装完。步级 `timeout-minutes: 6` + `continue-on-error` 双保险 |
| **1** | **开机瘦身** | `slim-image.ps1`：① 真卸载 `blockedApps`（9 个程序）→ ② 删镜像大件（约 70 GB）→ ③ 清空 `C:\Windows\Installer`（约 6.7 GB）→ ④ **残留清理**（删残留 ARP 卸载项 + 残留空壳目录）。`auto`/`always`/`off` |
| **2** | **C 盘守卫：记录基线** | `disk-guard.ps1 -Baseline`（**在瘦身之后**，基线反映瘦身后的起点） |
| 3–6 | AList 密码 / rclone / 部署 AList / （可选）迁移 139 | 139 挂载点 `/cloudrdp`；rclone / AList 都装在 `D:\cloudrdp-sys`；迁移仅当 `migrate_139=true` |
| **7** | **从 139 拉取数据** | `sync-down.ps1`（实测 ≈19 分钟；139 约 0.45 MB/s） |
| **8** | **预还原** | `pre-restore.ps1 -Pull`（拉取 → **用户名变更迁移** → 记录程序基线 → 校验 → 规划 → 回滚记录 → 驱动全量还原） |
| **8b** | **补写用户语言键** | `setup-chinese.ps1 -UserHiveOnly`：第 8 步会导入 `registry\user\HKCU-Software.reg`，把 0f 写的语言键覆盖掉 —— 这里再补一次（幂等、秒级） |
| **10** | **后台重装软件 + 恢复 Edge/WorkBuddy 用户数据** | `reinstall-apps.ps1 -Background`（异步，不阻塞）：winget 逐包重装 → 再对 Edge（浏览记录 / 已存密码 / 全部设置含下载位置）与 WorkBuddy（用户数据 / 缓存 / 安装目录）做完整性校验 + 缺失补漏 |
| **11** | **C 盘守卫：清理 + 报告** | `disk-guard.ps1 -Enforce` |
| **12** | **估算额度（仅手动触发）** | `if: workflow_dispatch` —— **定时场跳过额度检测** |
| **13** | ⭐ **环境就绪汇总（ENV READY）** | 初始化完成；含全部状态行（数据恢复 / 整机还原 / **中文语言包** / **Edge 与 WorkBuddy 用户数据取证（`USERDATA_RESTORE`）** / **失效快捷方式** / **邮件投递结果** / 快照一致性）+ 总耗时；桌面标记改名 `_CloudRDP_READY.txt` |
| 14 | 保活 | **主/单机**：每 10 分钟同步数据、每 60 分钟快照并推送；**备机**：每 10 分钟**重拉**、每 60 分钟只做本地快照（不写 139），每 5 分钟核对权威角色、主下线即自升为主。每 30 分钟 C 盘守卫。时长收敛到 `360 − 已用 − 8(余量)`。**最后 15 分钟在后台启动收尾**，主循环继续跑 → 远程连接全程不中断 |
| 15 | 等待后台收尾 | `if: always()`：等 finalize 后台作业完成（最多 4 分钟）；未启动才前台补跑。收尾 = C 盘清理 + 全量同步 + 整机快照（**备机**跳过同步/推送，只做本地快照） |

139 云盘内的存放位置：

| 路径 | 内容 |
|------|------|
| `AI文件库/CloudRDP/` | 用户数据（`D:\a\cloud-rdp` 的镜像） |
| `AI文件库/_snapshot/` | 整机快照（文件 / 注册表 / 软件清单 / 设置 / 快捷方式） |

---

## 六、常见问题

| 现象 | 原因 | 解决 |
|------|------|------|
| 第 5 步报「创建 139 存储失败」 | `Authorization` 过期或复制多了 `Basic` | 重新获取 Authorization，只取 `Basic ` 后那段，更新 Secret |
| 第 5 步报驱动不存在 | AList 版本驱动名不同 | 日志会打印可用驱动列表，改 `setup-alist.ps1` 里的 `$driverKey` |
| `sync-down` 退出码非 0 | 首次运行远端为空（正常）/ Authorization 过期 | 首次可忽略；否则更新 Secret |
| C 盘占用显示 80%+ | 瘦身被关了（`slim.mode=off` 或输入 `slim_image=off`），或瘦身失败 | 见 ⑦；把 `slim.mode` 改回 `auto`，或看日志里 `SLIM_STATUS` |
| `SLIM_STATUS=PARTIAL` | 清单没覆盖到某个大件 | 看日志里瘦身后的百分比；把大件路径加进 `snapshot-config.json` 的 `slim.targets` |
| 瘦身后某个程序打不开 | 它依赖被删掉的镜像组件（如 .NET / Java 运行时） | 把对应项在 `slim.targets` 里改 `enabled: false`，或让它装到 D 盘 |
| 瘦身太慢 | 删除 ~70 GB 需要几分钟；开了 DISM 更久 | 正常。想更快就把 `slim.targets` 里的大件精简 |
| 桌面 / 文档没了 | 旧版：有一次开机用户没登录 → 暂存被清空 → `rclone sync` 把云端那份删了 | **已修**：profile 不存在时保留上一份用户数据。若已丢，只能靠更早的备份 |
| 开机后桌面是空的 | `SNAPSHOT_USER_PRERESTORE=SKIPPED`（预创建 profile 失败） | 看 `D:\cloudrdp-sys\_state\user-restore.log`；登录任务会兜底重试，公共桌面会有失败标记 |
| Edge 登录态没了 | cookie/密码由 DPAPI 加密，跨机解不开 | 正常。用 Edge 账号同步恢复；历史/书签/偏好应该都在 |
| 快照推送很慢 | 体积不设上限 + 139 约 0.45 MB/s | 看日志 `SNAPSHOT_ETA_MIN`；大目录用 `copy` 可续传，下次接着传 |
| SMB(445) / AList(5244) 连不上 | 防火墙 | 已默认关闭；若被快照里的 `.wfw` 改回，还原后会再关一次 |
| 定时场不跑额度检测 | 按需求跳过（`if: workflow_dispatch`） | 正常。手动 Run workflow 才显示额度 |
| C 盘增量显示 `OVER` | 有大文件写进了 C 盘，或新程序装到了 C 盘 | 大文件放 `D:\a\cloud-rdp`；新装程序选 D 盘；或调大 `disk.maxIncrementalPercent` |
| 某程序还原后打不开 | 写死了绝对路径 / 需要注册服务 / 体积超上限被跳过 | 看日志里 `跳过：xxx`；调大 `programs.maxMBPerApp`，或设 `programs.preferJunction=false` 直接还原到原路径 |
| 安装型程序备份很慢 | 139 WebDAV 约 0.45 MB/s + 体积不设上限 | 正常，首次慢、之后只传变化；看日志 `SNAPSHOT_ETA_MIN`，大目录用 `copy` 可续传 |
| 上传大文件卡住 | 139 走 WebDAV 有 5 分钟超时 | 单文件建议 <500MB；超大文件用 139 官方客户端 |
| 连不上 100.x.x.x | 本地没登录 Tailscale | 本地客户端登录同一账号，`tailscale status` 检查 |
| 会话突然断开 | 6 小时到点，Job 被回收 | 正常，重新 Run workflow |
| 填了 `duration_minutes=350` 但实际只保活约 270 分钟 | **保活时长自动收敛**：`360（job 上限）− 已用（含 setup）− 8（余量）`。不收敛的话总时长会超 6 小时被强杀 | 正常且是刻意的。收尾已改到最后 15 分钟**后台**跑，不再占用可用窗口。想超过 6 小时请用 `relay_minutes` 接力（见第四节第 6 条） |
| 想连续用 48 小时 | 单 job 只有 6 小时 | 填 `relay_minutes=2880` 开启接力，会自动换机器续跑。**注意 IP 每轮会变** |
| job 起不来，7 秒就 `failure`，0 个步骤 | **额度封禁**（**只发生在私有仓库**）：本月用量超 2000 分钟且账号无可用的付款方式/支出上限 | **改公开仓库即可彻底解决**（无限额度，本仓库现为公开）；或到「Settings → Billing and plans」加付款方式/调高 spending limit，否则等次月 1 号重置。可用 `gh api repos/{owner}/{repo}/check-runs/{id}/annotations` 看确切原因 |
| `0e` 步骤显示「跳过发信」 | 没配邮箱 Secret（`MAIL_TO`/`MAIL_USER`/`MAIL_PASS`/`MAIL_SMTP_HOST`） | 正常降级，不影响开机；要收邮件就按第三节配齐这几个 Secret |
| `0e` 步骤报认证失败（`535`） | 把邮箱**登录密码**当成了 SMTP 授权码 | 到邮箱设置里开启 SMTP 服务并生成**授权码**（QQ：设置 → 账户 → POP3/SMTP服务 → 生成授权码） |
| 邮箱没收到连接信息 | 进了垃圾箱，或被收件方拦截 | 查垃圾箱；把发件邮箱加进白名单。也可从公共桌面 `_CloudRDP_*.txt` 直接取密码 |
| 整机还原显示 `PARTIAL` | 个别目录/注册表键还原失败（日志有明细） | 看日志 `[restore]` 行定位；多为该目录不存在或权限问题 |
| 登录后个人配置没回来 | 登录还原任务失败或未触发 | 查「任务计划程序」里的 `CloudRDP-RestoreUser`；日志在首次登录时不可见，可手动跑 `D:\cloudrdp-sys\_snapshot\_tools\restore-snapshot.ps1 -Scope user` |
| 改了账号名后桌面/文档空了 | 快照里的用户名与当前账号不一致（用户名被烤进了快照路径） | 看第 8 步日志里的 `SNAPSHOT_USERMIGRATE`：`OK` 表示已自动迁移；`SKIPPED` 且用户名确实变过 → 检查 `rdpuser-migrate.ps1` 是否随仓库一起更新；`FAILED` → 日志里有具体原因 |
| `SNAPSHOT_USERMIGRATE=SKIPPED` | 快照用户名已等于当前账号（正常，幂等跳过） | 无需处理。只有「用户名变了却没迁移」才需要排查 |
| 关机前的改动丢了 | Job 被**硬杀**（超时/取消太快），收尾步骤没跑完 | 保活期每 60 分钟会自动抓一次快照，最多丢 1 小时内改动 |
| 快照没上传 | `files.maxTotalMB` 被设成了有限值且已超 | 现在默认 `0 = 不限`；日志会告警并跳过后续目录 |
| 预检报「`AI文件库` 不存在」 | 139 里还没建这个文件夹（脚本刻意不自动创建） | 在 139 网页根目录下建好「AI文件库」后重跑；或改用「根 ID 法」（见 §4.⑥） |
| 139 上找不到数据 | 还在老路径 `/CloudRDP` | Run workflow 时勾 `migrate_139=true` 迁移一次 |
| 数据目录里混进了仓库文件 | rclone 排除规则没生效（`GITHUB_WORKSPACE` 与数据目录不匹配） | 看日志 `[sync-up] 排除:` 那行；确认里面有 `/cloud-rdp/**` 与 `/.git/**` |
| 可移动程序没被备份 | 被判定为「非可移动」（MSI 安装 / 落在系统目录 / 体积超限 / 命中黑名单） | 日志会打印候选数；要强制纳入可把路径加进 `portable.scanRoots` 或用 `files.dirs` 直接抓 |
| 可移动程序搬走机器变卡 | 用了 `portable.mode: "relocate"`（junction）且程序正被占用 | 改回默认 `copy`；relocate 是高级用法，会临时移动原目录 |
| winget 重装一直没动静 | 后台进程还在跑 / 清单为空（首次运行） | 看 `D:\cloudrdp-sys\_snapshot\_logs\apps-reinstall.log` 与 `apps-status.json`；首次运行无清单属正常 |
| 想跳过自动重装 | —— | Run workflow 时把 `install_apps` 填 `false` |
| `preCommands` 里的命令没生效 | 命令失败被 fail-soft 忽略（不阻断还原） | 看日志 `[pre-restore]   [n] 失败`；命令里建议用绝对路径 |
| 登录后还是英文界面 | 语言包没装成功（`CHINESE_LANGPACK=FAILED`），或快照里的英文 HKCU 覆盖了设置 | 看第 9 步日志；确认 `chinese.enabled=true` 且该步在「8. 预还原」**之后**执行 |
| 中文输入法打不出字 | 用户 hive 写入失败（`CHINESE_USERHIVE` 非 `OK`） | 看日志 `[chinese]` 行；登录任务会兜底。也可登录后到「设置 → 时间和语言」手动添加中文 |
| Unity Hub 又出现了 | 旧快照里含它 | 已在 `blockedApps`（开机**真卸载** + 从 winget 重装清单剔除）+ `programs.excludePaths`（不备份/不还原）三处排除；若仍出现，检查 139 上 `_snapshot/programs` 是否残留 |
| 想再卸掉某个镜像自带程序 | —— | 往 `snapshot-config.json` 的 `blockedApps.entries` 加一条（`name` / `match` 正则 / `wingetId` / `paths` / 可选 `services`），开机第 1 步会真卸载并清残留目录 |
| 卸载后又被装回来了 | `winget-export.json` 里还有它 | 已做三重过滤（重装侧剔除 + 备份时从清单删 + `excludePaths`）；若你手动改过配置，确认 `blockedApps.entries` 里的 `wingetId` 拼写正确 |
| 报「个人配置还原失败：`reg:HKCU-Software.reg`」 | **误报已修**。`reg import` 是 best-effort：`HKCU\Software` 里少数键**永远写不进去**（默认程序关联 `UserChoice` 有防劫持 ACL；`Feeds`/`Search` 被系统进程占用），旧代码把「99.8% 成功」当成了整文件失败 | 现在会自动拆块定位：只告警并列出失败键（属正常），不再计入 `problems`。日志形如 `HKCU 部分导入 HKCU-Software.reg：9/3934 块失败（系统保护/占用键，属正常）` |
| 桌面图标报「目标驱动器或网络连接不可用」 | 程序本体没被备份（该程序 Uninstall 键无 `InstallLocation`）→ 快捷方式成死链 | 见 ⑪：`shortcuts.captureTargets=true` + `programs.deriveInstallLocation=true` 会自动补抓；还原后校验会尝试修复，修不好的移入 `_失效快捷方式` |
| 死链指向的是**别人家的用户名**（如 `C:\Users\aigc\...`） | 快照里的 `.lnk` 把当时的用户名烤死在二进制里，换账号后必然失效 | **已修**：`Repair-Shortcuts` 会先把任意 `C:\Users\<别人>\` 改写成当前用户目录；再不行就按文件名去数据目录/便携程序根兜底定位（如 `D:\a\cloud-rdp\GameViewer\GameViewer.exe`） |
| 桌面多出 `_失效快捷方式` 文件夹 | 校验发现死链、且无法唯一定位到已还原的程序 | 正常（非破坏保留）。装回程序后把图标拖回桌面即可；该文件夹不会被再次备份 |
| 快捷方式补抓把大目录也抓了 | 该 `.lnk` 指向一个大目录（如某游戏） | 调小 `shortcuts.captureMaxMBPerTarget` / `captureMaxTotalMB`（超限会记名告警，不静默） |
| 不想让 WorkBuddy 数据被上传 | 它含对话记录 / 运行缓存，属敏感内容 | 从 `files.dirs` 删掉 `%RDPUSERPROFILE%\.workbuddy`（当前真实路径）、`.workbuddy-ai`、`AppData\Local\Programs\WorkBuddy`、`AppData\Local\WorkBuddy`、`AppData\Roaming\WorkBuddy` 那几行（改完提交即可） |
| 刚开机连进去发现桌面是空的 / 数据没同步完 | 你连得太早 —— `0d` 打印连接信息时，后台的数据同步与还原还没跑完 | 正常。等日志出现 `ENV READY`（第 13 步）再登录；或看公共桌面 `_CloudRDP_SETTING_UP.txt` → `_CloudRDP_READY.txt` |
| 早连后中文输入法打不出中文 | `0f. 设置中文` 的语言包还在后台装（30~43 分钟），或已登录时旧逻辑会因 `reg load` 失败而整段跳过 | **已修**：检测到已登录就直接写 `HKU\<SID>`（不 load/unload）；语言包 **5 分钟封顶转后台**，看 `LANGPACK=TIMEOUT_BACKGROUND` 即知。装完 `Win+Space` 切换或注销重登一次 |
| 公共桌面出现 `_CloudRDP_SETTING_UP.txt` / `_CloudRDP_READY.txt` | 提示初始化进度的标记文件（人在 RDP 里看不到 Actions 日志） | 正常，可随时删。已加进 `files.excludeFilePatterns`，不会被快照备份/还原 |
| 早连后程序图标还是死链 | 快捷方式校验（`8. 预还原` 里的 4e 段）跑完之后才修好 | 等 `ENV READY`；或手动跑 `D:\cloudrdp-sys\_snapshot\_tools\restore-snapshot.ps1 -Scope user` |
| **桌面只恢复了图标、点开报「找不到目标」**（用户级安装的程序） | **根因**：备份/基线扫描跑在 `runneradmin` 身份下，`HKCU:` 是它的 hive，**看不到用户 a 的卸载项** → 「程序体在 `%LOCALAPPDATA%\<厂商>`、卸载项在用户 HKCU」这一整类程序从没被备份 | **已修**：备份与基线两侧都用 `Get-InstalledProgramsIncludingUser`（自动挂载/读用户 hive，SID 归一化为 `HKU\__RDPUSER__`）。同时 **`programs` 现在先于 `files` 推送** —— 以前 `files` 吃掉 `--max-duration`，`programs/` 永远传不上去 |
| 卸载了程序但「应用和功能」里还在（如 Unity Hub） | 卸载器只删文件、没删自己的 ARP 卸载键（Unity Hub 的卸载器叫 `Uninstall Unity Hub.exe`，旧正则没给它补 `/S` → 挂起到超时） | **已修**：放宽静默参数匹配 + 新增 `④ 残留清理`（删残留 ARP 键 + 残留空壳目录），透出 `SLIM_ARP_CLEANED` / `SLIM_DIRS_LEFTOVER` |
| Edge 历史记录缺一段 / 快照报 `robocopy=9` | 抓取时 Edge 在运行，SQLite(WAL) 被持有；`LOCK`/`LOG` 这类 LevelDB 运行时文件也被独占 | **已修**：`excludeFilePatterns` 排除 `LOCK/LOG/LOG.old`（无还原价值）；**全量快照前自动关闭 Edge / WorkBuddy**（`files.quiesce`，快速快照不动）；还原时 robocopy 失败会用**共享读写**补写（`lockcopy-lib.ps1`）；还原后透出 `EDGE_RESTORE` / `USERDATA_RESTORE` |
| WorkBuddy 里的 `Cache` / `GPUCache` / `Temp` 没被备份 | `excludeDirNames` 按目录名全局排除，把用户数据目录里的缓存也滤掉了（Electron 缓存含登录态 / 离线数据，丢了等于重装） | **已修**：`files.noExcludeDirs` 豁免清单（`.workbuddy` / `.workbuddy-ai` / `AppData\Local\Programs\WorkBuddy` / `AppData\Local\WorkBuddy` / `AppData\Roaming\WorkBuddy` 共 5 个）—— 这些目录只禁用「目录名排除」，仍应用文件级排除 |
| **WorkBuddy 打开像全新安装（登录态 / 设置 / 历史全没）** | **根因**：快照清单里 WorkBuddy 只写了 `.workbuddy-ai`（旧路径，新版机器上根本不存在）→ **静默零还原**；安装目录与 `AppData\Local(Roaming)\WorkBuddy` 也从没被备份 | **已修**：清单补齐 5 处（见第四节「抓什么」）+ 第 10 步收尾用 `userdata-lib.ps1` 做**校验 + 补漏**（只补不删），结论透出 `USERDATA_RESTORE` / `WBAI_RESTORE` |
| 邮件没收到 | 0e 步带 `continue-on-error`，失败被静默吞掉 | 看 `D:\cloudrdp-sys\_state\mail.log`（逐步 SMTP 对话 + 失败阶段 + 常见错因提示）与 `MAIL_RESULT`。最常见：139/QQ 邮箱未开启「客户端授权码」、或端口被屏蔽（试 465/587） |

---

## 七、风险声明

- **非官方用途**：用 GitHub Actions 跑个人云桌面不符合其服务条款，长期使用可能被限流/封号。本仓库默认**私有**以降低暴露面，但**无法保证账号安全**。
- **不要存重要/隐私数据**：数据经 AList 非官方桥接写入 139 云盘，链路不保证稳定与安全。
- **快照含敏感文件**：`.ssh`、`.aws`、`.config`、`.vscode`、**`.workbuddy` / `.workbuddy-ai`（对话记录 / 缓存）** 等会被同步到 139 云盘。
  若不愿外传，请在 `scripts/snapshot-config.json` 的 `files.dirs` 里删掉对应条目（改完提交即可）。
- **可移动程序会被复制一份**：默认 `copy` 会在数据目录里留副本（占额外磁盘），
  体积上限见 `portable.maxMBPerApp` / `portable.maxTotalMB`；不想用就设 `portable.enabled=false`。
- **数据目录在 `D:\a\cloud-rdp`**：D 盘是 runner 的临时盘，机器销毁即消失 —— 持久化完全依赖 139，
  所以**务必确认每次运行日志里「数据恢复 / 整机还原」不是 `FAILED`**。
- **自动重装会跑很久**：402 个包可能几十分钟，期间机器可用但会占带宽/CPU；不想要就把 `install_apps` 填 `false`。
- **Authorization 约 15 天过期**：需定期手动更新 Secret，否则工作流会在第 5 步失败。
- **额度有限**：私有仓库约 5~6 次满时长会话/月，用完即停（Actions 会**静默停摆、不报错**）。
- **机器是一次性的**：Job 结束即销毁。已纳入快照的内容（见第四节）可自动还原，其余会丢失。
- **防火墙已关闭**（本项目要求）：机器无公网 IP、只走 Tailscale 内网，但内网可达面变大，请自行评估。
- **Edge cookie / 密码（`Login Data`）等敏感凭证会被上传到 139**：如不接受，把 `files.dirs` 里 Edge 那条删掉即可（代价：浏览记录 / 书签 / 已存密码都不再还原）。

> 如果需要**稳定可靠、数据持久、可定时开关机**的云主机，请直接购买低价 VPS（约 $5–15/月），比本方案靠谱得多。

---

## 八、推送到 GitHub（公开仓库）

```bash
# 在本目录下执行
git init
git add .
git commit -m "init: cloud-rdp"
git branch -M main

# 先在 GitHub 网页新建一个 Public 仓库，再把下面 URL 换成你的
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

> 已存在的仓库改公开：**Settings → General → 拉到最底 Danger Zone → Change repository visibility → Public**。
> 改公开是为了拿到**无限 Actions 额度**（私有仓库 2000 分钟/月，会被一次满时长 run 吃掉约 350 分钟）。

推送后别忘了在 **Settings → Secrets and variables → Actions** 配置 Secret：

| Secret | 用途 | 是否必需 |
|--------|------|----------|
| `TAILSCALE_AUTHKEY` | Tailscale 组网 | ✅ 必需 |
| `ALIST_139_AUTHORIZATION` | 139 云盘授权（约 15 天过期） | ✅ 必需 |
| `MAIL_TO` / `MAIL_USER` / `MAIL_PASS` / `MAIL_SMTP_HOST` | 开机后把连接信息发到邮箱 | 可选（见第三节） |
| `GH_BILLING_TOKEN` | 查官方 Billing API 拿账号级额度（需 `user` scope） | 可选（缺省回退本仓库估算） |

> RDP 账号密码**不在这里配** —— 它们写死在 workflow 顶部 `env:`，并且会在日志里明文打印（见第三节）。
