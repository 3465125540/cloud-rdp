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
| UU远程（GameViewer） | **设备身份两处都要**：机器级 `C:\ProgramData\Netease\GameViewer`（`user_info.ini` 的 `deviceId` / `config.ini` 的 `uuid` / `remote_assist_code.ini` 的协助码）+ 用户级 `%LOCALAPPDATA%\GameViewer`（`setting.ini`、内嵌 WebView2 的登录态）。漏一处 = 每轮新机器都被当成**全新设备**、反复要求登录/创建账号（见 §12） |
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

> **开机即预还原**：先用 `Initialize-RdpUserProfile`（`userprofile-lib.ps1`）**真正创建并注册**该用户的配置文件，
> 再 `reg load` 它的 `NTUSER.DAT` 导入 HKCU（把 `__RDPUSER__` 换成 `HKEY_USERS\_Restore`），最后 robocopy 个人文件。
> 这样**一开机桌面就是满的**，不用等首次登录。失败会自动回退到登录任务，行为与旧版一致。
>
> ⚠️ **踩过的坑（曾导致「Edge 还原后用户数据全丢」）**：`Start-Process -Credential` **不会**自动加载用户配置文件 ——
> `-LoadUserProfile` 是个**独立开关、默认 `$false`**；不传就只走 `CreateProcessWithLogonW` + `LOGON_NETCREDENTIALS_ONLY`：
> **进程能起来、不报任何错，但 `C:\Users\<用户>\NTUSER.DAT` 永远不生成**。于是用户级还原被静默跳过
> （旧日志里 `SNAPSHOT_USER_PRERESTORE=SKIPPED`、`EDGE_RESTORE: MISSING`），首次登录任务也依赖 profile 而一并失效。
> 现在统一由 `userprofile-lib.ps1` 处理：显式 `-LoadUserProfile` + `Wait-Process` + 轮询 `NTUSER.DAT`，
> 并带 **手动注册 `ProfileList`** 兜底（拷 `Default\NTUSER.DAT` + 写 `ProfileImagePath` + `icacls` 改属主）——
> 只建目录不注册，会让 Windows 首次登录改去 `C:\Users\<用户>.<计算机名>`，数据照样看不见。
> 创建失败会计入 `problems`，`SNAPSHOT_STATUS` 变 `PARTIAL`（不再无声）。
>
> HKCU 导出时会把 SID 归一化成 `__RDPUSER__` 占位符，换机后 SID 变了也能正确导入。

**还原状态**显示在同一处连接信息里：`OK` / `PARTIAL` / `EMPTY` / `FAILED`。

**已知边界**（做不到的，别指望）：

- 需要**授权码/硬件绑定**的商业软件，激活状态无法复刻
- Windows 更新状态、驱动、运行中的进程状态不涉及
- **Edge cookie / 密码跨机大概率解不开**（DPAPI 绑「用户+本机」）：历史、书签、偏好、`Web Data`、
  `Local Storage` / `IndexedDB`（不少站点把登录态存在这里）能回来，但 cookie 与已保存密码需靠 **Edge 账号同步**恢复登录态。
  还原阶段会**真去解一次** `Local State` 里的 `os_crypt.encrypted_key`，报 `EDGE_CRYPT=OK|BROKEN|UNKNOWN`
  （见日志 / ENV READY / `apps-status.json`），`BROKEN` 时直接提示去开 Edge 账号同步。另外 cookie 属敏感凭证，会被上传到 139
- **UU远程（GameViewer）的远程协助码跨机解不开**：设备身份里的 `deviceId` / `uuid` / `token` 是**明文**，
  会随快照跨机还原（这就是「UU远程 记住这台设备」的关键，见 §12）；但 `remote_assist_code.ini` 里的
  `code` / `customize_code` 是 **DPAPI 密文**，密钥绑旧机器 → 新机器上 UU远程 会**重新生成协助码**。
  每轮开机的结论会以 `UU_RESTORE=OK|PARTIAL|MISSING|N/A` 打在 ENV READY 里
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
  - 逐目标核对 **Edge**（`History` 浏览记录 / `Login Data` 本地已存密码 / `Preferences` 全部设置含下载位置 / `Bookmarks` / `Web Data` / `Local State`）、**WorkBuddy**（`.workbuddy` 用户数据+缓存、`.workbuddy-ai` 旧路径、安装目录、`AppData\Local\WorkBuddy`、`AppData\Roaming\WorkBuddy`）与 **UU远程**（机器级 `C:\ProgramData\Netease\GameViewer` 的 `user_info.ini`(deviceId) / `config.ini`(uuid) / `remote_assist_code.ini`(协助码)，用户级 `%LOCALAPPDATA%\GameViewer` 的 `setting.ini` / `setting_guest_anonymous_id.ini`）
  - 缺什么补什么：robocopy **只补不删**（不动你在机器上新增的文件）、幂等；补漏前先关闭占用程序，保证 SQLite(WAL)/LevelDB 一致
  - 结论写 `apps-status.json` 的 `userData` 字段，并透出 `USERDATA_RESTORE` / `USERDATA_RESTORE_DETAIL` / `EDGE_RESTORE` / `WBAI_RESTORE` / `UU_RESTORE`（第 13 步 ENV READY 会打印）
  - 目标清单在 `snapshot-config.json` 的 `restore.userDataTargets`（8 个：Edge 1 + WorkBuddy 5 + UU远程 2）；`restore.userData: false` 整体关闭；只重装不校验用 `-SkipUserData`

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
| **Edge 数据** | `files.dirs` 里加了 `%LOCALAPPDATA%\Microsoft\Edge\User Data`，并把它列入 `files.noExcludeDirs` —— **保住** `IndexedDB` / `Service Worker` / `File System`（很多站点的登录态存在这里，不只是 cookie）；纯缓存 `ShaderCache` / `Media Cache` / `Crashpad` 仍照删 |
| **UU远程（网易 GameViewer）设备身份** | 两处都要抓：① 机器级 `C:\ProgramData\Netease\GameViewer`（`deviceId` / `uuid` / 协助码）—— **它不是 `%RDPUSERPROFILE%` 系路径**，历史上从没进过清单；② 用户级 `%LOCALAPPDATA%\GameViewer`（`setting.ini`，底下是内嵌 WebView2，登录态在 `Cache`/`IndexedDB`/`Service Worker` 里）。两处都列入 `files.noExcludeDirs`，并在 `programs.dataGlobs` 里显式点名机器级那份作第二道保险。漏掉 = 每轮新机器都被 UU远程 当成**全新设备**，反复要求登录 / 创建账号（详见第四节 §12） |

- 开关：`programs.dataGlobs`、`registry.hkcr`
- **不做**：服务（`HKLM\SYSTEM\...\Services`）与计划任务（`System32\Tasks`）—— 按需求排除

> ⚠️ Edge 的 cookie / 密码由 **DPAPI**（绑「用户+本机」）加密，跨机后 SID 与机器密钥都不同 → **解不开**。
> 历史 / 书签 / 偏好 / `Web Data` / `Local Storage` / `IndexedDB` 能正常回来。要恢复登录态请用 Edge 账号同步。
> 还原阶段会真去解一次密钥并报 `EDGE_CRYPT`（见上「已知边界」）。
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
python workbench\selftest.py   :: 离线自测（620 项）
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

### 11. runner 掉线保命四件套（`The hosted runner lost communication with the server`）

**事故**：`build` 报 `The hosted runner lost communication with the server. Anything in your workflow that
terminates the runner process, starves it for CPU/Memory, or blocks its network access can cause this error.`

**日志取证**（拉全量 job 日志逐行比对，三次失败的 build 全部对上）：

| run | 死在 | 证据 |
|-----|------|------|
| `36124079866` | **第 8 步** | rclone 拉到 `99% (3.352 GiB, xfr#16230/18651)` 后最后一行 `14:32:36Z`，job 却在 `15:18:57Z` 才报 failure —— **中间 46 分钟日志凭空消失**；68,788 行里**没有任何** `##[error]` / `##[warning]` / `##[section]` |
| `35820523536` | **第 7 步** | step 永远停在 `in_progress`，后面步骤全 `pending`；job 耗 4h21m（预算 6h） |
| `35813312970` | **第 8 步** | step 2h26m 后变 `cancelled`，后续全 `skipped`；job 3h01m |

对照成功的 `35942568011`：第 7 步 2h36m、第 8 步 **48m56s**、job 5h58m —— 失败的 run 都死在
**数小时的 rclone 批量传输**里，且**日志中途无错截断**。这正是 GitHub 官方描述的 runner
**心跳发不出去**的特征（官方把「CPU / 内存被饿死」列为首因）。

> 顺带排除：全流程**没有**任何 `Restart-Computer` / `shutdown`；`snapshot-config.json` 不还原
> `Tcpip` / `NetworkList` / `hosts`；第 8 步带 `continue-on-error: true` 且 `timeout-minutes: 360`
> 从未触顶 —— 所以**死的是 runner 进程本身**，不是某个 step。

**四条根因 + 对策**（本次改动）：

| # | 根因 | 对策 | 落点 |
|---|------|------|------|
| ① | **Defender 实时扫描**：第 7/8 步要落地 ≈**1.8 万个小文件**，实时扫描逐个过一遍，在 4 vCPU 的 hosted runner 上足以把 CPU 吃光 → 心跳发不出 | 重 IO 之前先加**排除路径/进程**并**关实时扫描**（一次性机器；想保留实时扫描设 `CLOUDRDP_AV_KEEP_REALTIME=1`） | `watchdog-lib.ps1` → `Enable-RdpAvExclusions`；workflow **0a** + `sync-down` / `pre-restore` / `restore-snapshot` 三处调用 |
| ② | **Tailscale 接管系统 DNS**：`tailscale up` 默认把本机 DNS 改成 `100.100.100.100`，一旦 tailnet 开了 MagicDNS，runner agent 访问 `api.github.com` 的长轮询也会被拽进隧道 → 解析一抖就掉线 | `tailscale up` 加 **`--accept-dns=false`**（用户只认 `100.x` 裸 IP 连机器，关掉零副作用） | workflow **0c** |
| ③ | **拉取超时无穷大**：`--timeout 0 --contimeout 0`（当年为 139 WebDAV **上传**加的）用在**下载**上，一条僵死连接能吊到天亮 —— rclone 不报错、step 不结束 | pull 改 **`--timeout 5m --contimeout 60s`**；**push 保留 `0`**（139 WebDAV 上传 >5min 会被服务端断，动了就回归旧事故）。两方向都加 `--tpslimit 20` | `watchdog-lib.ps1` → `Get-RdpRcloneNetArgs -Mode pull\|push` |
| ④ | **网络瞬断不可见**：一次抖动就吃掉整场 run，日志里什么都看不到 | 独立**子进程看门狗**：每 60s 探一次 GitHub（DNS + TCP:443，**不用 ICMP** —— Azure 挡入站 ping），连续 3 次不可达就分级自愈（清 DNS 缓存 → 重连 Tailscale → 清 ARP，**绝不动网卡**）并打印明确判定「内存被吃光 / 网络被掐断」 | `conn-watchdog.ps1`（父进程消失即自行退出，绝不留孤儿） |

**新增/改动文件**：

| 文件 | 说明 |
|------|------|
| `scripts/watchdog-lib.ps1`（新） | 共享库：`Test-RdpGithubReachable` / `Get-RdpHostVitals` / `Enable-RdpAvExclusions` / `Get-RdpRcloneNetArgs` / `Invoke-RdpNetSelfHeal` / `Start-RdpConnWatchdog` / `Stop-RdpConnWatchdog` / `Repair-RdpProcessEnvDupes`。全部 fail-soft，缺库就退化成旧行为 |
| `scripts/conn-watchdog.ps1`（新） | 看门狗子进程；每分钟往 job 日志打一行 `[watchdog] gh=ok 空闲内存=… 磁盘=… top=…`，异常时打 `##[warning]` 并自愈 |
| `scripts/sync-down.ps1` / `pre-restore.ps1` / `restore-snapshot.ps1` | 拉取前 `Enable-RdpAvExclusions` + `Start-RdpConnWatchdog`，`try/finally` 收尾；rclone 参数统一走 `Get-RdpRcloneNetArgs` |
| `.github/workflows/windows-rdp.yml` | **0a** 加 Defender 排除；**0c** `tailscale up` 加 `--accept-dns=false` |

> **为什么不改 push 的超时**：`backup-snapshot.ps1` 推送 139 用的就是 `--timeout 0` —— 那是**真机踩出来的**
> （139 WebDAV 上传大文件超过 5 分钟会被服务端断开）。本次只收敛**拉取**方向，推送方向原样保留。

**运维开关**：`CLOUDRDP_AV_SKIP=1`（跳过 Defender 调整）、`CLOUDRDP_WATCHDOG_SKIP=1`（跳过看门狗）、
`CLOUDRDP_AV_KEEP_REALTIME=1`（只加排除项、不关实时扫描）。

### 12. UU远程 每次都当新设备 / 反复要求「登录 / 创建账号」

**现象**（瑀子 2026-09-26）：每轮新机器起来后，UU远程 都像**第一次装**一样，要求登录 / 创建账号 / 重新绑定设备。

**真机取证**（直接 SMB 读在线云机 `github-rdp-server-66` / `100.98.87.44`，以 RDP 用户 `a` 身份）：

| 观察 | 数据 | 结论 |
|------|------|------|
| 程序本体 `C:\Program Files\Netease\GameViewer\GameViewer.exe` | `ctime=2026/9/26 14:57:37` 但 **`mtime=2026/9/17 21:23:14`** | robocopy `/COPY:DAT` **保留了原始修改时间** → 是**还原来的**（不是刚装的）。说明「桌面快捷方式线索补抓程序本体」这条链是通的 |
| `C:\ProgramData\Netease\GameViewer\*`（`user_info.ini` / `config.ini` / `remote_assist_code.ini` / `user_setting.ini` / `cache_setting.ini`） | ctime/mtime 全是开机时刻 `09-26 14:57~14:58` | **UU远程 现建的**，不是还原来的 —— 快照里根本没有它们 |
| `%LOCALAPPDATA%\GameViewer\setting.ini` | `remoteassist_guide=true` / `remoteassist_guide_step=0` | 应用自己认为「**首次使用引导还没走完**」 |
| `C:\Users\` 一级目录 | 只有 `a` / `Public` / `Default` / `Default User` / `runneradmin` | 所谓「新账户」**不是 Windows 账户**，是 UU远程 自己的设备/账号概念 |
| `user_info.ini` | `deviceId=aeawvn3m5abc6x6a` / `token=` / `userId=` | ⚠️ **token/userId 为空是正常态** —— 本机（已正常使用）也是同样的空值。UU远程 免登录也能远程协助，「是不是新设备」由**明文 `deviceId` / `uuid`** 决定，不是账号 |
| `user_info.ini` 的 ACL | `SYSTEM` / `Administrators` = FullControl，`Users` = ReadAndExecute | **不是权限问题** —— `runneradmin`（属 Administrators）读得到 |
| `snapshot-config.json` 全文 grep | `Netease` = 0，`GameViewer` = 0，`UU` = 0；`files.dirs` 25 条里 **零条** `ProgramData`；`programs.dataGlobs` 为空 | **根因：这两处身份文件从没进过快照清单** |

**根因**：UU远程 的设备身份分成机器级 + 用户级两处，**都不在原来的清单覆盖范围内**：

```
机器级  C:\ProgramData\Netease\GameViewer\        ← 机器级路径，不是 %RDPUSERPROFILE% 系
          user_info.ini      deviceId（明文，设备指纹）
          config.ini         uuid
          remote_assist_code.ini   远程协助码（code/customize_code 是 DPAPI 密文）
用户级  %RDPUSERPROFILE%\AppData\Local\GameViewer\
          setting.ini / setting_guest_anonymous_id.ini
```

`files.dirs` 是围绕 `%RDPUSERPROFILE%` 写的（外加 `C:\scripts` / `C:\apps` / `%PUBLIC%\Desktop`），
而备份/还原脚本以 **`runneradmin`** 身份跑、`C:\ProgramData` 又是**机器级**路径 —— 两头都不搭，
于是这份「设备身份证」**每轮都被丢掉**，新机器在 UU远程 眼里就是一台**全新设备**。

**对策**（`snapshot-config.json` 一处配置搞定，无需改脚本逻辑）：

| 落点 | 改动 |
|------|------|
| `files.dirs` | `+ C:\ProgramData\Netease\GameViewer`、`+ %RDPUSERPROFILE%\AppData\Local\GameViewer`（25 → 27 条） |
| `files.noExcludeDirs` | 同样两条（6 → 8 条）。用户级那份底下是内嵌 WebView2，登录态在 `Cache`/`IndexedDB`/`Service Worker` 里 —— 不豁免就会被 `excludeDirNames` 按目录名一起排掉（与 Edge、`.workbuddy` 同一个道理） |
| `programs.dataGlobs` | 显式点名 `C:\ProgramData\Netease\GameViewer`，作为 `files.dirs` 之外的第二道保险（重复命中会被已抓判断跳过，不重复占带宽） |
| `restore.userDataTargets` | `+ UU远程（机器级）` / `+ UU远程（用户级）`（6 → 8 个目标），收尾会**校验 + 补漏**，结论透出 `UU_RESTORE` |

**分流怎么走**（不需要额外代码）：`restore-snapshot.ps1` 按镜像路径前缀自动分作用域 ——
`C\ProgramData\...` 不匹配 `c\users\<用户>` → 走**机器级**，开机第 8 步由 `runneradmin` 还原；
`C\Users\<用户>\AppData\Local\GameViewer` → 走**用户级**，第 8 步 4d 段预还原 + 首次登录任务兜底。

**代价**（实测云机，不拍脑袋）：机器级那份 **5 个文件 / ≈0 MB**；用户级那份 **295 个文件 / 32.21 MB**
（其中 `webviewcache` 291 个 / 32.21 MB —— 就是内嵌 WebView2 的登录态缓存）。按 139 实测 0.45 MB/s 算，
**每轮快照只多约 70 秒**，换来「UU远程 认识这台设备」。程序本体 `C:\Program Files\Netease\GameViewer`
（198 个 / 292.65 MB）由「桌面快捷方式线索补抓」负责，**本次改动不涉及**。

**验证**（离线自测 + 真机冒烟，全 PASS）：

| 检查 | 结果 |
|------|------|
| `selftest.py` | **441 PASS / 0 FAIL**（UU远程 那批 T137/T142b–g + T316–T324；§13 加 T325–T336；§14 加 T337–T348；§15 加 T349–T355；§16 加 T357–T365） |
| 真机冒烟（`Get-UserDataTargets` / `Find-UDSnapshotDir` / `Invoke-UserDataVerifyAndRepair`） | 目标解析 8 个含 UU远程 2 个；快照定位含**用户名迁移尾部兜底**；`UU_RESTORE` 在 OK / PARTIAL / MISSING 三态下判定正确且真写进 `GITHUB_ENV` |
| 35 个 `scripts/*.ps1` AST 解析 | 全通过；两个 JSON + 两个 YAML 合法（26 步） |

> **⚠️ 诚实边界（不假装全好了）**：`remote_assist_code.ini` 里的 `code` / `customize_code` 是 **DPAPI 密文**，
> 与 Edge 的 `os_crypt` 同一类问题 —— 密钥绑「旧机器 + 旧用户」，**跨机解不开**，所以**协助码会被 UU远程 重新生成**。
> 真正能跨机带过去、也是「让 UU远程 记住这台设备」的是**明文** `deviceId` / `uuid` / `token`。
> 想彻底免掉「新设备」提示：在 UU远程 里**登录 UU 账号**（账号级设备绑定存在服务端，`token` 是明文、会随快照还原）。
> 每次开机的结论都会在 ENV READY 里以 `UU远程设备 : OK / PARTIAL / MISSING` 打印出来，不用去猜。

### 13. 每次备份都显示「备份不完整」（`SNAPSHOT_STATUS=PARTIAL`）

**现象**（瑀子 2026-09-26）：工作台「快照」一列**每次**都显示不完整（`SNAPSHOT_STATUS=PARTIAL`），
但远端文件数其实**不少于**本地。

**真机取证**（`joblog-35591676811.log` / `edge-run-latest.log`）：

| 观察 | 数据 | 结论 |
|------|------|------|
| 抓取完成的**瞬间**就已判 PARTIAL | `[snapshot] 抓取完成：9853 个文件 / 1429.24 MB / 状态 PARTIAL` | PARTIAL **不是**推送失败造成的 —— 抓取侧（纯本地、无网络 I/O）就定了 |
| 推送本身是健康的 | `SNAPSHOT_PUSH: OK` / `SNAPSHOT_VERIFY: OK`，远端 `10029` 个文件 `1901 MB` ≥ 本地 `9853` / `1429.24 MB`，全程约 38 秒 | 「不完整」是**假警报**，不是数据丢失 |
| 还原侧 4 条固定告警 | `missing:C\Users\a\Documents` / `Pictures` / `Videos` / `Music` | 每次都是**同样这 4 个空目录** |
| 这 4 个目录的真实体积 | `-> 0 个文件 / 0.00 MB`（全新机器的用户目录天然为空） | 它们**本来就该是空的** |
| `[完整抓取] .workbuddy-ai` 间歇告警 | `源 8772 / 暂存 8748（差 24）`（09-21 出现；09-23 三次运行均无） | 另有一条**间歇性**假警报 |

**根因**（两条，本质都是「把正常当成缺失」）：

```
① 空目录被当成缺失
   backup-snapshot.ps1 给**每个**配置目录都记一条 files.entries（含 files=0 的空目录）
   -> rclone copy 不带 --create-empty-src-dirs 就不会在 139 建空目录
   -> pre-restore.ps1 的 2a 一律 Test-Path -> 4 个 missing: -> $problems -> PARTIAL
   （讽刺的是：sync-up.ps1 一直在用 --create-empty-src-dirs，只有 backup-snapshot.ps1 漏了）

② 文件符号链接被当成「该抓的文件」
   robocopy 的 /XJ 官方定义 =「排除(文件和目录的)符号链接和接合点」-> **文件符号链接也不抓**
   而 Get-ExpectedFileCount 用的 Get-ChildItem -Recurse -File 会把文件符号链接当普通文件数进去
   -> .workbuddy-ai 的 24 个文件符号链接 -> 「差 24」-> $problems -> PARTIAL
   （实测：目录接合点 Get-ChildItem 本就不展开，只有文件符号链接会多算）
```

**对策**（`backup-snapshot.ps1` / `pre-restore.ps1` / `snapshot-config.json`）：

| 落点 | 改动 |
|------|------|
| `pre-restore.ps1` 2a | 条目自带 `files` 字段且 `<= 0` → **跳过**缺失判定（空目录不算缺失；字段缺失的老 v1 清单仍按原逻辑校验，不掩盖真缺失） |
| `backup-snapshot.ps1` 推送 | 加 `--create-empty-src-dirs`：空目录也真的建到 139（与 `sync-up.ps1` 口径一致，根治 ①） |
| `backup-snapshot.ps1` 计数 | 新增 `Get-FilesNoReparse`：目录/文件一律按 `ReparsePoint` 跳过；`Get-TreeSize` / `Get-ExpectedFileCount` 都改用它 → 与 `/XJ` **完全一致**，根治 ② |
| `backup-snapshot.ps1` 计数时机 | 期望文件数改为 robocopy **之前**统计（活跃目录抓完再数，会把期间新产生的文件算成「差 N」） |
| `backup-snapshot.ps1` 诊断 | 新增 `Get-MissingFileNames`：文件数不足时**列出具体文件名**（前 10 个），不再只给一个数字 |
| `snapshot-config.json` | `programs.excludePaths` `+ D:\a\cloud-rdp` —— 它就是 `CLOUDRDP_DATA_DIR`，已由 `sync-up.ps1` 每 10 分钟独立同步；不排除会被当成「已装程序」整棵抓进 `programs/`（真机 2736 个文件、纯重复上传） |

**顺带修掉的推送隐患**（同一批，均为真机踩过的）：

| 隐患 | 原行为 | 现行为 |
|------|--------|--------|
| 元数据排最后 | `programs → files → 元数据 sync`；`--max-duration` 到点 → 远端**没有** `manifest.json` | 改为**元数据 → programs → files**（manifest 是还原的「总目录」，必须先落地） |
| 整段共用一个预算 | `files` 是大头（≈20 分钟），会把 `programs` 饿死 → 远端永远没有 `programs.json` → 下次开机桌面只剩图标 | **分阶段预算**：元数据 / programs / files 各一段 `--max-duration`（programs 按自身体积估算 + 保底 3 分钟） |
| 大目录失败仍报 OK | `copy` 返回非 0 只 Warn，最后元数据 `sync` 成功即 `SNAPSHOT_PUSH=OK` | 大目录未传完 → `SNAPSHOT_PUSH=PARTIAL`（不再谎报） |

**验证**（离线自测 + 真机等价复现，全 PASS）：

| 检查 | 结果 |
|------|------|
| `selftest.py` | **441 PASS / 0 FAIL**（本批 T325–T336；§14 另加 T337–T348 共 12 条；§15 另加 T349–T355 共 7 条） |
| `Get-FilesNoReparse` vs 真 `robocopy /XJ` | 真接合点 + 真文件树实测：两边计数**完全一致**（旧口径会多算） |
| `Get-MissingFileNames` | 删掉暂存里一个文件 → 精确点出 `b.txt`，且**不会**误报被 `excludeFilePatterns` 排除的 `c.tmp` / `desktop.ini` |
| 35 个 `scripts/*.ps1` AST 解析 | 全通过 |

> **诚实边界**：本次改的是**判定口径**，不是「把 PARTIAL 藏起来」。真正的失败信号仍然照报 ——
> robocopy 返回码 `>=8`（`file:$src`）、关键文件远端缺失（`SNAPSHOT_VERIFY=PARTIAL`）、
> 远端文件数少于本地（`SNAPSHOT_VERIFY=PARTIAL`）、大目录未传完（`SNAPSHOT_PUSH=PARTIAL`）一个都没放宽。

### 14. 云机上那个 `runneradmin` 账户 —— 它到底是谁、为什么删不掉、怎么让它看不见

**现象**（瑀子 2026-09-28）：连上云机后能看到一个叫 `runneradmin` 的账户，
以为是「UU远程 / 云机自己新建的」；诉求是 **只需要有一个管理员账户 `a`，不要自动创建新的用户账户**。

**真机取证**（SMB 只读探两台在线云机 `100.75.73.81` / `100.85.24.112`，不是猜）：

| 观察 | 数据 | 结论 |
|------|------|------|
| `runneradmin` 的 profile 元数据 | `ctime = 2026/9/22 22:26:18`、`NTUSER.DAT mtime = 09/22 22:56:20` —— **两台机器完全一致** | 是**镜像烘焙时**就有的，不是哪一次开机、哪一个脚本建的 |
| 与本次开机时间的关系 | 本次开机 `2026-09-28 00:45Z`，而 ctime 是 `09-22` | 早于任何一次开机 ⇒ **不是开机流程建的** |
| 全仓 grep（含 `.github`） | `New-LocalUser` / `net user` / `Add-LocalGroupMember` / `Remove-LocalUser` / `Disable-LocalUser` / `wmic useraccount` **只命中 workflow 第 0b 步**（建 `a`） | **流程只建 `a` 一个账户**，别的账户都不是我们建的（现已由 **T348 常驻守护**：全仓 `.ps1/.py/.yml/.json/.cmd/.vbs` 逐行扫，0b 之外任何建账户代码都会让自测失败） |
| `runneradmin` 的身份 | `runs-on: windows-latest`；工作区是 hosted 专属的 `D:\a\<repo>\<repo>`；`slim-image.ps1` 硬保护名单里就有 `C:\actions-runner` | `runneradmin` = **GitHub-hosted runner 自己的 Windows 账户**（本次 job 的 runner agent 正以它身份在跑） |
| UU远程 是否建账户 | `C:\Program Files\Netease\GameViewer\` 里是 `GameViewer.exe` + **`GameViewerService.exe`**（服务） | UU远程 = 网易 GameViewer，**只装服务、不建 Windows 账户**；它的「设备/账号」是应用自己的概念（见 §12） |
| `C:\Users\` 一级目录 | `a` / `runneradmin` / `Public` / `Default` / `Default User` | 与 §12 一致，没有第三张「新面孔」 |

**根因**：`runneradmin` 是 **GitHub 托管 runner 的基础设施** —— 不是「UU远程 建的」，也不是流程建的。
真机日志里那两条

```
快捷方式线索跳过：LightC.lnk -> 目标不存在: C:\Users\runneradmin\AppData\Local\LightC\LightC.exe
快捷方式线索跳过：UU远程.lnk -> 目标不存在: C:\Users\runneradmin\Downloads\GameViewer\GameViewer.exe
```

之所以出现 `C:\Users\runneradmin\...`，只是因为**备份脚本本身以 `runneradmin` 身份在跑**，
`%LOCALAPPDATA%` / `$env:USERPROFILE` 自然指到它的 profile —— 并不是「UU远程 装到了 runneradmin 下」。

**诚实边界（不假装能全做到）**：`runneradmin` **删不掉**。
本次 job 的 runner agent 就是以它身份在跑，删它 / 降它的权 = 当场把 job（连同这个远程桌面）弄死；
它也不归我们管（GitHub 镜像的一部分）。所以**能做且该做的是「让它彻底看不见」**，
于是「用户视角只有 `a` 一个管理员账户」。

**对策**（新增 `scripts/account-lib.ps1`，两条都可逆、fail-soft）：

| 落点 | 改动 |
|------|------|
| ① 登录界面隐藏 | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList\<name> = 0` —— 锁屏 / 切换用户 / UAC 凭据选择器 / 「用户账户」控制面板都不再列它。**认证本身不受影响**（显式指定用户名照样能登），runner 服务更不受影响 |
| ② profile 目录隐藏 | `attrib +h +s C:\Users\<name>` —— 资源管理器默认不显示（即便开了「显示隐藏文件」，system 属性仍会被「隐藏受保护的操作系统文件」挡掉） |
| ③ 白名单断言 | `Test-RdpAccountWhitelist`：除「`a` + 内置账户 + `runneradmin`」之外的账户一律判为**异常** —— 直接对应「不要自动创建新的用户账户」。**开机（0b）与保活循环各查一次**，不是只查一次 |
| ④ 报告透出 | workflow 第 13 步 ENV READY 打一行 `账户 : 唯一可见 = a  已隐藏 runneradmin, …`；有未知账户时另打黄字告警 |
| ⑤ 顺手修误导 | `backup-snapshot.ps1` 的「快捷方式线索」把**其它用户 profile**（尤其 `C:\Users\runneradmin`）加进 `-SkipPrefixes` —— 那些死链再也不会出现在日志里把人带偏 |
| ⑥ 会话中监控 | 保活循环（第 14 步）**每 10 分钟**复核白名单：没变化就留一条 `[account] 账户白名单复核通过` 的正面证据；真冒出未知账户 → **黄字点名**（写出账户名）+ 顺手隐藏 —— 把「开机一次性断言」升级成「全程监控」，任何时刻建的账户都跑不掉 |

**调用点**：workflow **第 0b 步**（建完 `a` 立刻隐藏 + 白名单），结论写 `ACCOUNT_HIDE` / `ACCOUNT_UNKNOWN` 进 `GITHUB_ENV`；
**第 14 步保活循环**每 10 分钟再复核一次（日志前缀 `[account]`）。

**运维开关**：

| 开关 | 作用 |
|------|------|
| `CLOUDRDP_ACCOUNT_HIDE=0` | 跳过隐藏（什么都不做） |
| `CLOUDRDP_ACCOUNT_HIDE_DRYRUN=1` | 只看不改（打印将隐藏谁） |

**撤销**：`. scripts/account-lib.ps1; Restore-RdpHiddenAccounts -RdpUser a` —— 删掉 `SpecialAccounts` 项 + 目录属性复原。

**验证**：

| 检查 | 结果 |
|------|------|
| `selftest.py` | **441 PASS / 0 FAIL**（T337–T348 账户批共 12 条 + T349–T355 池行批共 7 条 + T356 会话中复查 1 条）。其中 **T348 已升级为全仓审计**（`.github` / `workbench` / `deploy` 全扫），不只 `scripts/` |
| `account-lib.ps1` 本机 dry-run 冒烟 | 清单 / 白名单 / 隐藏计划 / 报告行四个函数全部正常返回，无异常 |
| 35 个 `scripts/*.ps1` AST 解析 | 全通过；YAML 合法（26 步） |

### 15. 「机器运行实况」把已结束的机器一直显示成「运行中」（信息同步异常）

**现象**（瑀子 2026-09-28）：机器实况里 `acc-3` 那一行显示
「运行中 · Actions job 运行中 · run 36343475821」，但**同一台机器**在「账号」面板里早已是「已结束 · 成功」。

**真机取证**（GitHub API + 工作台 API，不是猜）：

| 观察 | 数据 | 结论 |
|------|------|------|
| 账号面板（走实时） | `acc-3 source=live, running_count=0, last_run=completed/success` | 实时口径：**已结束** |
| 机器实况（走快照） | `run_status=in_progress, machine_state=running` | 快照口径：**还在跑**（陈旧） |
| 那个 run 的真相 | run `36343475821`：`status=completed` / `conclusion=success` / `updated_at=2026-09-28T01:11:55Z`（2.19 小时前） | 确实早就结束了 |
| 协调器最后一次发布 | `pool-state.updated_utc = 2026-09-28T01:03:13Z` | **正好卡在 run 结束之前**抓的快照 |

**根因**：`pool-state` 是 `pool-coordinator.yml` **每隔几小时**（GitHub cron 常被延迟 2~5 小时）发的**快照**，
不是实时状态。协调器抓快照那一刻 run 还在 `in_progress`，之后 run 结束、协调器还没重跑 ——
于是「机器实况」一直信快照说「在跑」，而「账号面板」走 `hub_live_probe` 实时查早已说「已结束」，
**两个面板打架**。

**修法**（`workbench/server.py` + `static/app.js`）：

| 落点 | 改动 |
|------|------|
| `live_runs_by_id()`（新） | hub 账号（= 工作台自己配的那个仓库）→ `{run_id: 实时 run}`；非 hub → `None`。走 `get_runs("keepalive")` **同一份缓存**，几乎零成本 |
| `pool_machine_rows()` | 有实时 run 就按它**纠偏** `run_status/conclusion/url`，并加 `run_source`（`live` / `pool-state`）标记来源 |
| 前端池行徽标 | 结束且 `success` → 「已结束 · 成功」；tooltip 按 `run_source` 说明「已按 GitHub 实时 run 核对」还是「协调器快照可能滞后几小时」 |

**口径**：能实时查的（hub 账号）一律实时；查不到的（fork / 不可读）才回落到快照，并**显式标注**来源。

**验证**（离线自测 + 真机等价复现）：

| 检查 | 结果 |
|------|------|
| `selftest.py` | **441 PASS / 0 FAIL**（本批 T349–T355 共 7 条） |
| 功能实测 | 快照说 `in_progress`、实时 run 说 `completed` → 池行纠偏为 `ended` / `run_source=live`；拿不到实时（非 hub）→ 保持快照 `running` |
| 真机核对 | 修复后 `/api/pool_machines` 返回 `machine_state=ended / run_conclusion=success / run_source=live`；页面池行显示「已结束 · 成功」 |

> **诚实边界**：这只是让**两个面板口径一致**，不改变「机器是一次性的」这个事实 ——
> run 结束后机器本就会销毁，Tailscale 上看不到它的节点是正常的。真正的「在跑」仍以 GitHub 的 run 状态为准。

### 16. UU远程 连上看到的是 `runneradmin`、不是 `a`（账户不一致）

**现象**（瑀子 2026-09-28）：用 UU远程 连上云机，落到的桌面是 `runneradmin` 的，不是 `a` 的。

**根因**（真机事实，不是猜）：

| 事实 | 说明 |
|------|------|
| UU远程 = 网易 GameViewer，是**屏幕镜像**型工具 | 它连的是机器的**控制台会话**（console session，即"物理显示器"上那个会话），**不是**像 RDP 那样新建一个会话 |
| 控制台会话现在是谁的？ | GitHub-hosted 镜像把 **`runneradmin` 放在控制台**（runner 本体就在那跑）→ 所以 UU远程 默认显示 `runneradmin` |
| 仓库里有没有自动登录 / 会话脚本？ | **没有**（全仓 grep `AutoAdminLogon` / `DefaultUserName` / `tscon` / `query session` 只命中文档，以及账户守卫的 `Winlogon\SpecialAccounts`） |

**第一版修法（2026-09-28，已被推翻）**：公共桌面放「切到 UU远程」快捷方式，双击时直接
`tscon <本会话ID> /dest:console`。**2026-09-29 真机实测发现这条路走不通**（见下）。

**2026-09-29 真机实测**（acc-5 · `github-rdp-server-91` · `100.86.253.112`，console = `runneradmin`、`a` = 会话 1）：

| 做法 | 结果 |
|------|------|
| 以 `a` 的普通令牌 `tscon 1 /dest:console` | ❌ **Error 5 / Access is denied**（需要 `SeTcbPrivilege`，普通令牌没有） |
| 以 SYSTEM 单独 `tscon 1 /dest:console` | ❌ 只把 `a` 断开（变 `Disc`），**顶不掉已被占用的控制台**（`runneradmin` 仍在 console） |
| 以 SYSTEM **先 `tsdiscon <控制台会话ID>`、再 `tscon <a会话ID> /dest:console`** | ✅ **成功**：控制台变成 `a`，`runneradmin` 变 `Disc` |

> 关键顺序铁律：**`tsdiscon` 必须在 `tscon` 之前**。反过来先 `tscon` 会返回 `rc=0` 但控制台纹丝不动
> （实测两次都失败）—— 因为控制台被 `runneradmin` 占着，必须先把它断开腾出控制台。

**因此改成「三层」设计**（不删账户、不动 runner、绝不 `logoff`）：

```
① SYSTEM 计划任务 CloudRDP-UUHandover（按需触发、无触发器）
     → 以 SYSTEM 令牌执行 tsdiscon <控制台> + tscon <a会话> /dest:console（SeTcbPrivilege 只在 SYSTEM 有）
② 公共桌面快捷方式「切到 UU远程」
     → 普通令牌双击，只负责「触发 ①」，自己绝不去 tscon（所以不会撞 Error 5）
③ SYSTEM 计划任务 CloudRDP-UUAuto（开机 + 每 60s 无限重复）—— 2026-09-29 追加
     → 无感：控制台不是 a、且 a 的会话没被 RDP 连着（Disc）时，自动执行 ①
```

- 只**断开 / 重定向**，**绝不 `logoff`** —— 会话不注销、程序不退出；
- 顶掉控制台上的 `runneradmin` 只是把它**断开**（detached），`Runner.Listener` / `Runner.Worker` 不受影响；
- `GameViewerServer` / `GameViewerHealthd` 会自动在**新的**控制台会话里重生（PID 变，但服务不丢）—— 对 UU远程 与 runner 都安全。

**③ 为什么能「无感」，又为什么必须加闸**（瑀子 2026-09-29 要求「连 UU远程 时无感跳到 `a`」）：

| 场景 | `a` 的会话状态 | 自动交接怎么做 | 为什么 |
|------|----------------|----------------|--------|
| 控制台已经是 `a` | — | 直接退出（幂等，不做事、不刷日志） | 已经是目标状态 |
| 你正用 mstsc 连着 `a` | **`Active`**（`rdp-tcp#N`） | **不切**（`skip-active`） | 切了会把你这次 RDP **踢断**；你若重连，Windows 会把控制台会话「**接管**」回 RDP，任务下一轮又切回来 → **来回抢控制台**。这种情况留给你自己决定：双击②立刻切 |
| 你登录过 `a`、现在断开着 | **`Disc`** | **切** | 这正是「我想用 UU远程」的状态：Disc 说明**没有任何 RDP 客户端挂着**，把该会话 `tscon` 到控制台**不会踢掉任何人**，UU远程 立刻看到 `a` |
| `a` 还没有会话（全新开机、没登录过） | 无会话 | 什么都不做 | 没有可交接的会话（日志/ENV 会说明） |

- 触发节奏：**开机一次 + 每 60 秒一次**（`-AtStartup` + `-Once -RepetitionInterval`）。PS 5.1 实测
  `-AtStartup` **不支持** `-RepetitionInterval`，所以拆成两个触发器；重复周期**不设 `RepetitionDuration`**
  ⇒ `Duration` 为空 ⇒ 永续。
- 想关掉自动：仓库里设 `CLOUDRDP_UU_AUTO=0`（安装时跳过），或在机器上放一个开关文件
  `<sysdir>\_state\uu-auto-off`（运行时立刻停摆）。真正发生交接时才会往 `<sysdir>\_state\uu-auto.log` 写一行。

| 落点 | 改动 |
|------|------|
| `scripts/session-lib.ps1`（重写） | `Get-RdpSessionReport`（解析 `qwinsta`，**状态锚定**；暴露 `aState` / `aSessionName` / **`aAttachedRdp`**）/ `Format-RdpSessionReport` / `Get-RdpHandoverPlan`（纯函数，四态 `none` / `no-user` / **`skip-active`** / `handover`，`-Auto` 启用自动闸）/ `Invoke-RdpSessionHandover`（**需 SYSTEM**，`tsdiscon`→`tscon`）/ `Install-RdpSessionHandoverTask`（装 ① + ② + **③**）/ `Install-RdpSessionHandoverShortcut` / **`Install-RdpSessionAutoHandoverTask`**（只装 ③） |
| `scripts/session-handover.ps1`（重写） | 四模式：`-System`（SYSTEM 任务入口，真正交接）/ **`-Auto`**（③ 入口：SYSTEM、静默、幂等、Disc 闸）/ `-DryRun`（只打印计划，可与 `-Auto` 合用）/ 默认 `-Apply`（用户双击：只**触发** SYSTEM 任务并轮询结果）。全程 fail-soft |
| workflow **第 0b2 步** | 诊断控制台归属 → 写 `CONSOLE_OWNER`；`Install-RdpSessionHandoverTask` 一次装齐 ①②③ |
| `scripts/send-connection-mail.ps1` | **老 fork 自愈钩子**：下发连接邮件时顺带 `Install-RdpSessionHandoverTask`（fail-soft）。`0p` 只同步 `scripts/` ⇒ 停在 `d67e81d` 的老 fork（没有 `0b2` 步）也能装上 ①②③ |
| workflow **第 13 步** | ENV READY 打一行 `会话控制台 : <谁>` |
| workflow **第 14 步保活循环** | 每 10 分钟复查控制台归属，**只在归属变化时**打一行 `[session] …` |

**怎么用**：

1. 以 `a` 通过 mstsc 登录（正常流程；顺带触发用户级数据还原）；
2. **断开** mstsc（关窗口即可）→ ≤1 分钟内自动交接 → `a` 成为控制台会话；
3. 打开 / 重连 UU远程 → 看到的就是 `a` 的桌面（若仍显示旧画面，断开重连一次）；
4. 想立刻切（不想等那 1 分钟，或你正 RDP 连着）：双击公共桌面 **「切到 UU远程」**；
5. 想切回 RDP：再用 mstsc 以 `a` 登录即可（Windows 会把 `a` 的会话接回 RDP；此时自动闸**不会**跟你抢）。

**验证**（2026-09-29 在 `100.86.253.112` / `100.111.1.59` 真机跑通）：

| 检查 | 结果 |
|------|------|
| `selftest.py` | **494 PASS / 0 FAIL**（§16 本批 T400–T418 共 19 条；含 T411/T418「真跑 pwsh」） |
| 部署 | `session-lib.ps1` 23,395 B / `session-handover.ps1` 10,097 B 字节级一致落到 `D:\cloudrdp-sys\scripts` |
| 任务 | `CloudRDP-UUHandover`：`state=Ready`、`user=SYSTEM`、`logon=ServiceAccount`、`runlevel=Highest`；`CloudRDP-UUAuto`：同 principal + `AtStartup` & `Once`(`PT1M`, 无 Duration) 双触发器 |
| 快捷方式 | 公共桌面 `切到 UU远程.lnk` → `powershell.exe -File …session-handover.ps1 -Apply -User "a"` |
| 端到端交接 | BEFORE `console runneradmin 2 Active` / `a 1 Disc` → `tsdiscon 2 rc=0` + `tscon 1 /dest:console rc=0` → AFTER `console a 1 Active` / `runneradmin 2 Disc` |
| 自动闸 | 布局 `rdp-tcp#0 a 1 Active` → `-Auto` 判 `skip-active`（不抢）；布局 `<空> a 1 Disc` → `-Auto` 判 `handover` |
| 解析回归 | 断开布局 `<空名> a 1 Disc` 下仍识别 `a`=会话 1（旧解析会误判 `no-user`） |
| AST + YAML | 三个脚本 + 第 0b2 / 13 / 14 步脚本全部解析通过；YAML 解析出 26 步、`0b2` 在 |

> **诚实边界**：交接需要 `a` **先有一个会话**（即先用 mstsc 登录一次）—— 因为 GitHub 托管 runner 的
> `HostedComputeAgent` 任务以 `runneradmin` 的 **InteractiveToken** 运行（`AutoAdminLogon=runneradmin`），
> 改自动登录会把 runner 弄死；而 job 中途也没法重启去走「自动登录 `a`」。所以「开机就自动让 `a` 占控制台」做不到，
> ③ 只解决「你已经登录过 `a`，只是不想再手点一次」这一步。
>
> **老 fork 注意**：Actions 用的是**触发 commit 里的 workflow**，`0p` 只 `/MIR` `scripts/`。
> 停在 `d67e81d`（2026-09-24）的 acc-5 **没有 `0b2` 步** ⇒ 只能靠 `send-connection-mail.ps1` 里那个下沉钩子装 ①②③；
> 而 `send-connection-mail.ps1` 是 `0p` 覆盖得到的文件 —— 这就是「fork 无法自愈 workflow，但能自愈 scripts」的落点（详见 §17）。

### 17. 老 fork「同步了脚本却还是旧逻辑」：`0p` 只覆盖 `scripts/`、覆盖不到 `workflow`（acc-5 事故复盘）

**现场**（瑀子 2026-09-28，`acc-5 · code19698fgh`，`池内机器 · standby`，`100.78.202.22`，run `36382948275`，job `4h16m`）：

| 步骤 | annotation |
|------|-----------|
| `0p. 跟随上游 hub 同步脚本（fork 自愈，永不跑旧逻辑）` | `Process completed with exit code 1.` |
| `8. 预还原（校验 → 规划 → 准备 → 驱动全量还原）` | `The operation was canceled.` |

**根因 ①（`0p` 报错 = 假警）**：`0p` 用 `robocopy /MIR` 把 hub 的 `scripts/` 镜像到本机。
robocopy 的退出码**不是**「成功 / 失败」——`0 = 无变化`、`1 = 有复制`、`2 = 有额外文件`、`3 = 1+2`，**这四个都算成功**，只有 `>= 8` 才是真失败。
而 GitHub 会给 `shell: pwsh` 的步骤**自动追加 `exit $LASTEXITCODE`** → 一旦真的复制了文件（`rc=1`），整步就被判成失败。

> 所以这条 annotation 其实是**「同步成功」的证据**：脚本确实从 hub 拉下来了。纯属误报。

**根因 ②（step 8 被 cancel = 老 fork 吃不到保命参数）**：

| 事实 | 说明 |
|------|------|
| acc-5 的 fork 停在 `d67e81d`（2026-09-24 14:50 +0800） | 它是 fork 来的，自己不会往前跑 |
| 保命四件套 `fbbfd48`（2026-09-26）**晚于**它 | 见 §11 之② |
| `0p` 只 `/MIR` 同步 `scripts/`，**改不到 `.github/workflows/`** | Actions 用的是**触发 commit 里的 workflow**；运行期改工作区里的 workflow 文件不生效 |
| ⇒ fork 内联的 `0c` 里**没有** `--accept-dns=false` | 而该参数只写在 workflow（`scripts/*.ps1` 里根本没有），`0p` 永远送不到 |
| 本 tailnet 已开 **MagicDNS**（`tailf6704b.ts.net`） | `tailscale up` 把整机 DNS 抢成 `100.100.100.100` → runner agent 访问 `api.github.com` 的长轮询被拽进隧道，一抖就发不出心跳 → GitHub 中途把 job 判成 `cancelled` |

**决定性对照**：**hub** 自己（`3465125540/cloud-rdp`，workflow 里**有** `--accept-dns=false`）同一天、同一个 tailnet 跑，
step 8 正常跑完、整场 **6h04m**；acc-5（缺这个参数）跑到 **4h16m** 挂在 step 8。**唯一差别就是这个参数。**

**修法**（两条，缺一不可）：

| # | 改动 | 落点 |
|---|------|------|
| ① | **归一化 robocopy 退出码**：`$rc = [int]$LASTEXITCODE; $global:LASTEXITCODE = 0`，只在 `rc >= 8` 时提示，步骤末尾显式 `exit 0` —— 别再报假警 | workflow **0p** |
| ② | **把 DNS 兜底「下沉」到 `scripts/`**：新增 `Repair-RdpTailscaleDns`（幂等、fail-soft），在任何重 IO 之前先 `tailscale set --accept-dns=false` 并清 DNS 缓存 —— 这是 **`0p` 覆盖得到**的文件，**任何 fork** 只要同步过脚本就会被修一次 | `scripts/watchdog-lib.ps1`（新函数）+ `sync-down.ps1` / `pre-restore.ps1` / `restore-snapshot.ps1`（各调一次） |

> **为什么兜底要下沉到 `scripts/`**：fork 无法自愈 workflow（`0p` 改不到），但**能**自愈 `scripts/`。
> 把「保命」放进 `0p` 能覆盖的文件里，老 fork 下次开机就自动拿到 —— 不用人去点 Sync。

**可见性**：`0p` 现在会 SHA256 比对「本 fork 的 `windows-rdp.yml`」与「hub 的 `windows-rdp.yml`」，
不一致就打一行 `[upstream] ⚠️ 本 fork 的 workflow 与 hub 不一致 …`（**只 `Write-Host`，不打 `::warning`** —— 免得又刷出一条 annotation）。

**运维开关**：`CLOUDRDP_TAILSCALE_DNS_SKIP=1`（跳过 DNS 兜底、不动本机 Tailscale 配置；本地单测用）。

**验证**：

| 检查 | 结果 |
|------|------|
| `selftest.py` | **450 PASS / 0 FAIL**（本批 T366–T374 共 9 条） |
| AST 解析 | `watchdog-lib` / `sync-down` / `pre-restore` / `restore-snapshot` + `0p` 的 run 块全部通过 |
| `actionlint` | `rc=0`（全部 workflow） |
| 编码 | `scripts/*.ps1` = **BOM + CRLF**；`windows-rdp.yml` = **无 BOM + CRLF**（逐字节校验，零裸 LF） |

> **诚实边界**：① 这个 DNS 故障是**间歇性**的 —— acc-5 更早一次 run（`36363377079`）就顺利过了 step 8。
> ② workflow 里的 `--accept-dns=false`（§11 之②）**仍是第一道防线**；脚本级兜底是给「`0p` 够不到 workflow」的老 fork 的**后手**。
> ③ 老 fork 的**根治**仍然是把它与上游 **Sync 一次**（`0p` 现在会打印这条建议）。

### 18. 「机器运行实况」主机列显示「账号未知」+ 实况刷新不准确（v1.6.2）

**现象**（瑀子 2026-09-28）：
① 机器实况里 `100.64.46.76` 那一行的「主机」列显示 **「账号未知」** —— 可它明明**在线**（`github-rdp-server-*`，Tailscale 上看得见）。
② 「实况刷新不准确」：点「刷新」后时间戳不动 / 一直挂着「后台刷新中」，看到的总是旧数据。

**真机取证**（工作台 API + 系统命令，不是猜）：

| 观察 | 数据 | 结论 |
|------|------|------|
| 节点是否在线 | `/api/overview`：`machines` 共 **88 个**节点，其中 **2 个在线**（`100.123.203.79`、`100.64.46.76`） | 机器确实在跑 |
| ping | `100.64.46.76` 平均 **204 ms**，0 丢包 | 网络通 |
| TCP 445 / 3389 | **OPEN** | 端口开着 |
| SMB 预鉴权 | `net use \\100.64.46.76\D$ /user:a a` → **系统错误 67「找不到网络名」** | **读不到远端文件** |
| SMB 枚举 | `net view \\100.64.46.76` → **1702「绑定句柄无效」**；`IPC$` / `C$` / `D$` / `admin$` / `cloudrdp` / `Users` 全部报 **67** | 机器侧 SMB 栈还没起来 |
| 同批另一台 | `100.123.203.79` → 读到 `acc-3 · 3465125540` | 对照：SMB 通的那台就正常 |

**根因**（六个缺陷，两两一组）：

*「账号未知」这一组* —— 归属要读机器上的 `_state\pool-info.txt`（来源①）或 runner 工作区 `D:\a\<repo>\<repo>\.git\config`（来源②），**两者都走 SMB**；SMB 一断，两条路一起断：

| # | 缺陷 | 后果 |
|---|------|------|
| 1 | `_smb_preauth()` 无论成功失败都当「已处理」，把 IP 记进 `_SMB_DONE` | 机器 `D$` 后来共享出来了，这个 IP 也被**永久拉黑**，再不重试 → 永远「账号未知」 |
| 2 | `job_tailscale_ip()` 把**空结果**也缓存 **3600 秒** | 机器还在初始化时查不到 IP，这一小时内**再也学不到** |
| 3 | 两条归属路都断时**没有任何兜底** | 只能干显示「账号未知」 |

*「刷新不准确」这一组*：

| # | 缺陷 | 后果 |
|---|------|------|
| 4 | `overview_seconds=20` < 实测构建耗时（13~49 秒） | 快照**一建出来就已过期** → 每个请求都触发重建 → 永远「后台刷新中」，时间戳冻住 |
| 5 | `stale` 被写成「比 TTL 老」，而不是「真的在重建」 | UI 误报「正在后台重建」，其实没人在建 |
| 6 | 点「刷新」时若正好有请求在途，`if (BUSY) return` **静默丢掉这次点击**；按钮也无禁用/无进度 | 用户以为没反应，反复点 |

**修法**（`workbench/server.py` + `static/app.js`）：

| 落点 | 改动 |
|------|------|
| `_smb_preauth()` / `_smb_preauth_once()`（新） | **成功才**记进 `_SMB_DONE`；失败记 `_SMB_FAIL[ip]` + **60 秒冷却**后自动重试；`clear_cache()`（点「刷新」）会清掉冷却，立刻重试一次 |
| `job_tailscale_ip()` | 学到 IP 就**长期记住（1 小时）**；**空结果只缓存 60 秒**（机器还在开机就下一轮再学） |
| `pool_ip_accounts()`（新） | **来源③兜底**：扫账号池里 `in_progress` 的 keepalive run，从其 job 日志自报的 `[0c] Tailscale IP` **反查 IP → 账号**。刻意**不用** `last_run`（结束的 run 的 IP 可能被新机器复用 → 会张冠李戴） |
| `collect_machines()` | 在来源①②之后追加来源③；只补 `pool_owner` 为空的行（**权威优先，不覆盖**），并标 `owner_source` |
| `smb_err_text()`（新） | 把 `Errno 22/13/2/53/67` 翻成人话（如「远端共享不可达：机器上 `D$` 还没共享出来」），写进 `error` 字段，前端 tooltip 直接展示 |
| `_overview_ttl()` | TTL 取 `max(配置值, 实测构建耗时 + 5 秒)` —— 快照不再「一建出来就过期」 |
| `_overview_build()` | 实测构建耗时存进 `_OV["build_secs"]`，供上面用 |
| `overview_snapshot()` | `stale` 改成**只表示「确实有重建在途」**（`building or dirty`），不再等于「比 TTL 老」 |
| `static/app.js` | 新增 `REFRESHING` 状态机 + `setRefreshBtns()`（禁用两个刷新按钮、文案改「刷新中…」）+ `updateStamp()`（显示「更新于 HH:MM:SS（N 秒前）」；刷新中显示「刷新中…（当前数据 N 秒前）」）；`FORCE_PENDING` 兜住「请求在途时点的刷新」，等它结束**自动补发** |

**口径**：能实时查的（hub 账号）一律实时；归属**依次**尝试 ① `pool-info.txt` → ② `.git\config` → ③ 账号池反查 IP，前一条读到了后一条**不覆盖**。

**验证**（离线自测 + 真机等价复现）：

| 检查 | 结果 |
|------|------|
| `selftest.py` | **475 PASS / 0 FAIL**（本批 T375–T399 共 25 条：含 `_smb_preauth` 成功/失败、冷却 → 点刷新重试、`job_tailscale_ip` 空结果 60 秒后重学、`pool_ip_accounts` 只认 `in_progress`、来源③补位且不覆盖、TTL 兜底与 `stale` 语义等 6 条功能实测） |
| 真机核对 | 修复后 `/api/overview`：`100.64.46.76 → acc-1 · yc1966asgf`（`error: ""`）、`100.123.203.79 → acc-3 · 3465125540`，**「账号未知」消失** |
| 刷新实测（无头浏览器真点 `#btn-refresh`） | 点击前「更新于 19:40:44（27 秒前） · 正在后台重建」→ 点击后两个按钮**禁用**、文案「刷新中…」、时间戳「刷新中…（当前数据 29 秒前）」→ 约 **30 秒后收敛**为「更新于 19:41:42（0 秒前）」，按钮恢复可用 |

> **诚实边界**：① 当机器侧 SMB 完全不可读（`net use` 错误 67 / `net view` 1702）时，两条归属路都会失败 ——
> 此时「主机」列仍会显示「账号未知」，但 tooltip 会**说清原因**（`D$` 未就绪），且点「刷新」会立刻重试一次，
> 机器就绪后**自动补上**。② 同一情形下 `role` 列仍显示「单机」（角色徽标不消费 `error` 字段，属另一处决定，本批未改）。
> ③ `stale` 现在**只**表示「有重建在途」，不表示「数据旧」；数据新旧看时间戳里的「N 秒前」。
### 19. 概览「恢复异常 N 数据」虚高：失败标记经 139 传播 + 旧标记被当成现役失败（v1.6.3）

**现象**：概览页「恢复异常」卡片显示 `3 数据 · 0 快照`（副标题「未从 139 拉取成功的机器数」）。逐台核查后发现：**其中 2 台根本没失败过** —— 它们拿到了别的机器写下的失败标记。

**真机取证**（2026-09-30）：

| 机器 | 账号 | 开机时刻（`_state/job-start.txt`） | `_state/restore-status.json` | 数据目录里的标记文件 | 判定 |
|---|---|---|---|---|---|
| `100.113.113.57` | acc-3 | `05:49:01Z` | **不存在** | `_RESTORE_FAILED.txt`：`restore FAILED at 2026-09-30 04:00:58, rclone exit code = 1` | **假阳性**（标记比开机早 1h48m） |
| `100.122.116.23` | acc-1 | `00:45:50Z` | **不存在** | 与 acc-3 **逐字节相同**的同一行 | **假阳性**（两台机器不可能同一秒失败） |
| `100.105.185.106` | acc-5 | `00:46:42Z` | **存在**，`data.status=FAILED`、`reason=远端可达但 copy 失败（rclone 码 1）` | 时间一致 | **真失败** |

两台机器的标记文件时间戳**完全一致**（`2026-09-30 04:00:58`），其中一台的标记还**早于它本次开机** —— 独立机器不可能在同一秒失败，只能是**同一个文件被复制了过去**。

**根因（两个缺陷叠加）**：

| # | 缺陷 | 位置 | 后果 |
|---|---|---|---|
| 1 | 标记文件躺在数据目录根（`D:\a\cloud-rdp\_RESTORE_*.txt`），而数据目录整个是 139 同步范围，排除表只挡了 `/.git`、`/_temp`、`/cloud-rdp` | `sync-up.ps1` / `sync-down.ps1` 的 `$excludeList` | 一台机器的失败标记被推上 139，再被还原到**别的**机器；几天后仍被读成「本机恢复失败」 |
| 2 | 工作台回退读标记文件时**只测存在、丢弃内容**（`at_utc` 写死为空），无法判断它是「本次开机产生」还是「从别处还原来的老文件」 | `server.py` `read_restore_status()` | 陈旧标记与新鲜失败无法区分，一并计入「恢复异常」 |

补充：标记文件有**两代格式** —— 旧版（`ce302e7` 时代的 `sync-down.ps1`，`Get-Date -Format 'yyyy-MM-dd HH:mm:ss'`，**本地时间、无时区**）与现行版（`remote-lib.ps1` 的 `Set-RestoreStatus`，UTC ISO-8601、带 `Z`）。现行脚本**任何一次运行都会同时写 `restore-status.json`**，所以「有标记、无 JSON」本身就说明该标记不是现行脚本本次写下的。

**修法**：

| # | 改动 | 位置 |
|---|---|---|
| 1 | 数据目录同步**排除** `_RESTORE_FAILED.txt` / `_RESTORE_EMPTY.txt`，从源头掐断传播 | `sync-up.ps1`、`sync-down.ps1` |
| 2 | 回退读标记时**连内容一起读**，解析出 `at_utc` / `marker_legacy`；旧版格式、或时间早于本机本次开机的，标 `stale_marker=True` | `server.py` `read_restore_status()` / `parse_marker_time()` / `_mark_stale_marker()` |
| 3 | 「恢复异常」计数（`count_scope_bad`）与摘要（`machine_restore_summary`）**跳过** `stale_marker` | `server.py` |
| 4 | 机器表「恢复」列把陈旧标记渲染成灰色「旧标记·已忽略」，tooltip 说明成因 —— **不计数，但也不悄悄吞掉** | `static/app.js` `restoreLine()` |

**口径**：

- 权威来源永远是 `_state\restore-status.json`。它存在时，标记文件一概不看（哪怕状态是 `FAILED`）—— **acc-5 的真失败照常计入**。
- 标记文件仅在 JSON 缺失时兜底；且只采信「现行格式 + 时间晚于本机本次开机」的。
- 旧版格式（本地时间、无时区）一律视为陈旧：当前脚本已不再产生该格式。

**验证**：

| 检查 | 结果 |
|------|------|
| `selftest.py` | **504 PASS / 0 FAIL**（本批 T419–T428 共 10 条：同步脚本排除项、两种标记格式解析、陈旧判定三分支、权威 JSON 不被误判、计数与摘要跳过陈旧、前端文案） |
| 真机（生产代码路径 `build_overview`） | 同一批机器：修复前 `machines_data_bad=3`，修复后 `=0`；唯一仍带标记的 acc-3 被标为 `stale_marker=true`、`reason=（旧版标记文件 _RESTORE_FAILED.txt：本地时间、当前脚本已不再产生）` |

> **诚实边界**：① 修法**不隐藏真失败** —— acc-5 的 `data=FAILED`（权威 JSON）在修复前后都计入，用例 T425 专门钉住这一点。② 已还原到机器上的旧标记**不会自动消失**，但会在该机下一次 `sync-down`（`Set-RestoreStatus` 每次先删两个标记）时清掉；清掉之前界面显示「旧标记·已忽略」而非静默。③ 139 上已存在的历史标记文件不会被本次改动删除（工作台不直接读写 139），只是**不再被拉回机器**。

### 20. 自动接力：机器运行时长 ≥ 4 小时 → 自动派发 1 台新机器（v1.6.4）

**背景**：单 job 硬上限 6 小时（见 `windows-rdp.yml` 的 `relay_minutes` 说明）。机器跑到第 4 小时就该把
「下一台」排上队 —— 否则等它到点结束，中间会出现一段没有机器的空窗。这条规则把「看表接力」交给工作台的
后台守护线程，**面板关着也照跑**。

**规则四要素**：

| 要素 | 说明 |
|------|------|
| **触发条件** | 后台守护线程每 `check_seconds`（默认 60 秒）巡检一次；只要「命中集合」非空、且通过下面三道去重护栏，就触发一次派发 |
| **判断范围** | **所有在跑的机器**（不限主/备、不限账号）：`auto_start_hot()` 从「机器运行实况」列表里挑出 `online 且 uptime_seconds ≥ 4h` 的机器，**任意一台达标即命中**。排除：离线机器、池内占位行（`pool_only`，无运行时长）、读不到 `_state\job-start.txt` 的机器（时长未知） |
| **执行动作** | 派发 **1 台**保活机：`POST /repos/<repo>/actions/workflows/windows-rdp.yml/dispatches`（等价于「操作台 → 派发保活机」那一下），入参 `duration_minutes / install_apps / migrate_139` 由配置给 |
| **去重/重复触发** | ① **一次性闩锁**：按「归属@开机时刻」（`machine_uptime_key`）记进 `workbench/_auto-start-state.json`，同一台机器触发过永不再触发；② **冷却期** `cooldown_minutes`（默认 30）：两次派发至少间隔这么久，防多台同时到点时「一次性全起」；③ **滚动配额** `max_per_hour`（默认 4）：一小时内最多派发几台；④ 可选 `max_running`：在跑机器数达上限就不再派发。**只有派发成功才落闩锁**，失败不闩、下个 tick 重试（仍受冷却约束） |

**关键设计取舍**：

* **为什么按「归属@开机时刻」而不是 IP 去重**：一次性 runner 的 Tailscale 节点可能重连换 IP，但一次 run 的
  开机时刻唯一且不变 —— 认「同一台机器的一生」，才不会漏闩（该闩没闩）或误闩（把新机器当成旧的）。
* **为什么运行时长单调递增也不怕重复**：正因为只增不减，才必须靠闩锁 + 冷却压住；否则每个 tick 都会命中。
* **默认关闭**：自动派发会消耗 GitHub Actions 分钟数，属于「要花资源的自动化」，默认 `enabled: false`。
  开启：本机 `workbench/config.json` 写 `{"auto_start":{"enabled":true}}` 并重启服务。`auto_start` 走**子键合并**，
  只写 `enabled` 不会丢掉其余阈值（`load_config` 对嵌套 dict 做了一层拷贝，不会污染内置默认值）。

**配置**（`workbench/config.json`；全量见 `workbench/config.example.json`）：

```json
"auto_start": {
  "enabled": true,          // 总开关（默认 false）
  "uptime_hours": 4,        // 阈值（小时）
  "cooldown_minutes": 30,   // 冷却期（分钟）
  "max_per_hour": 4,        // 每小时配额（0 = 不限）
  "max_running": 0,         // 在跑机器数上限（0 = 不限）
  "duration_minutes": "350",
  "install_apps": true,
  "migrate_139": false,
  "check_seconds": 60
}
```

**可观测**：`GET /api/auto-start`（只读；加 `?dry=1` 干跑一次判定、但不派发不落状态）；概览载荷新增
`auto_start` 字段；「机器运行实况」标题行显示「自动接力：任一台运行 ≥ 4 小时 → 自动派发 1 台（已派发 N 台，上次 …）」。
去重闩锁/历史落盘 `workbench/_auto-start-state.json`（已 gitignore）。

**验证**：

| 检查 | 结果 |
|------|------|
| `selftest.py` | **547 PASS / 0 FAIL**（本批 T455–T471 共 17 条：范围/边界、未启用不触发、闩锁去重、冷却、每小时配额、在跑上限、只读接口与干跑、默认关闭、配置子键合并不污染默认值） |
| 真机干跑（`auto_start_run_once(dry_run=True)`） | 3 台在跑机器（5h41m / 5h26m / 4h34m）全部 ≥ 4h → `fire=true`，取最老的 `100.110.211.37`，`dispatched=false`（干跑不派发、不落状态） |

> **诚实边界**：① 规则**只看 Tailscale 在线的机器** —— 机器若「Actions job 在跑但 Tailscale 掉线」，
> 它的运行时长读不到，本规则不会因它触发（这类机器在「机器运行实况」里是池内占位行）。② 派发是**入队**、
> 不是「立刻多一台」：同仓库 `windows-rdp.yml` 配了 `concurrency`，若该仓库已有 job 在跑，新 run 会排队到
> 前一台结束 —— 这正是「接力」想要的行为。③ 规则**不做跨账号编排**：派发落在 `config.repo`（hub）上，
> 具体哪台机器起来由 workflow / 账号池决定，不保证与「到期的那台」同账号。

### 21. 界面账号显示：代号 `acc-N` → 真实账号名（v1.6.5）

**问题**：「定时计划运行日志」的账号筛选 tab 显示 `acc-1 / acc-3 / acc-4 / acc-5` —— 代号看不出是谁，
机器表的「主机」列、账号管理表也都在混用代号。

**修法**：前端统一一个口径 `accLabel(id, owner)`，**所有**显示账号的地方都走它：

| 兜底顺序 | 取值 | 例 |
|---|---|---|
| ① 有真实账号名 | `owner` | `code19698fgh` |
| ② 只有代号 | 去 `/api/accounts` 反查 `owner`；查到就用真实名 | `acc-5` → `code19698fgh` |
| ③ 反查不到 | 退回代号本身 | `acc-99` |
| ④ 连代号都没有 | 「未命名账号」 | — |

**改动点**（`workbench/static/app.js`）：

* `renderRunAccTabs()` —— 账号筛选 tab（截图那一行）→ 真实名；tooltip 保留「代号 acc-N」。
* `runGroupHead()` / `renderRuns()` —— 分组表头与「N 条记录」meta → 真实名。
* `renderMachines()` / `poolOnlyRow()` —— 机器表「主机」列第二行的账号名 → 真实名（tooltip 里带代号 + 来源）。
* `renderAccounts()` —— 账号管理表主显示仍是真实名；代号降级成第二行「代号 acc-N」小字。
* 代号**没有删除**，只是从「主显示」降级到 tooltip / 小字 —— 仍能与 `scripts/pool-config.json` 的 `acc-N` 对上。

**验证**：`selftest.py` **554 PASS / 0 FAIL**（本批 T472–T478）；另用**真实** `/api/accounts` + `/api/runs?accounts=1`
数据在 Node 里跑真实渲染函数，账号 tab 实际产出 = `全部账号 | yc1966asgf | 3465125540 | code1969sda | code19698fgh`，
分组表头 rg-id 同名；兜底链 16 项断言全过。

### 22. 账号凭证报错「人话化」：403 → 该重新生成 PAT 了（v1.6.6）

**现象**：账号管理表的「凭证」列显示 `查询失败`，备注行摊出一串 .NET 异常：
`Response status code does not indicate success: 403 (Forbidden).` —— 看不懂，也不知道该干什么。

**真机取证**（2026-10-04，hub 协调器 run `37165902257` 日志）：

```
[pool] 账号 acc-1 (yc1966asgf)：查询失败 —— Response status code does not indicate success: 403 (Forbidden).
[pool] fork 自愈：acc-1 (yc1966asgf) 未同步 —— compare 失败：... 403 (Forbidden).
[pool] 派发失败 → acc-1 (yc1966asgf) —— ... 403 (Forbidden).
```

* 同一个 token 的**读 runs / compare / 派发 workflow 全部 403** ⇒ 问题在 token 本身，不是某个接口。
* 该 Secret **没被改过**（`POOL_TOKEN_1` 的 `updated_at` 仍是 2026-09-22）⇒ 不是被覆盖，是 token 自身失效。
* 时间线（逐 run 扫描）：**2026-10-03T01:19Z 还正常**（「在跑 1 台 / 排队 1 台」），**05:54Z 起连续 403**。

**修法**：前端把原始报错翻译成「人话 + 行动建议」（`explainTokenError()`）：

| HTTP | 徽标 | 含义 / 怎么办 |
|------|------|----------------|
| 403 | `凭证被拒 · 403`（红） | PAT 已过期 / 被吊销 / 权限不足（classic 需 `repo`+`workflow`；fine-grained 需 Actions 读写 + Contents 读写并勾选该仓库）→ **重新生成 PAT 并更新该 Secret** |
| 401 | `凭证无效 · 401`（红） | PAT 已被删除 / 吊销 → 重新生成 |
| 404 | `仓库不可见 · 404`（红） | PAT 看不到该仓库（仓库已删/改名，或未授权给它） |
| 429 | `被限流 · 429`（黄） | 速率限制，会自动恢复（非配置问题） |

徽标 tooltip 与备注行都给人话；**原始报错串降级到 tooltip** 里备查（不丢证据）。
非 HTTP 类的报错（如「Secret 未配置」）原样透传，不做误翻译。

**验证**：`selftest.py` **563 PASS / 0 FAIL**（本批 T479–T483）；另用**真实** `report_note`
（就是那串 403）在 Node 里跑真实 `explainTokenError()`：→ `凭证被拒 · 403 / bad`，12 项断言全过。

> **诚实边界**：本批只改**显示**，不碰协调器、不改池状态；**token 失效这件事本身仍需人工换 PAT**
> （工作台拿不到账号自己的 PAT，Secret 值 GitHub 也永不回显）。另：协调器的「派发失败」目前**不写进
> 池状态**，所以面板看不到「这个账号派发不出去」——那是另一个待补的观测点。

### 23. 账号故障「可诊断」：API 报错必须带上响应体（v1.6.7）

**现象**：账号面板只显示光秃秃的 `403 (Forbidden)` / `422`，**看不到 GitHub 说的原因**，排查像猜谜。

**根因**（2026-10-04 本地 pwsh 实测）：

```
Invoke-RestMethod 非 2xx → 抛 HttpResponseException
  .Exception.Response            = HttpResponseMessage        （有）
  .Exception.Response.GetResponseStream()  → 方法不存在
  .Exception.Response.Content.ReadAsStringAsync()
      → "Cannot access a disposed object: HttpConnectionResponseContent"
```

即：**抛错时响应体已被 dispose，任何 catch 里的补救都读不回来**。项目原来的写法
（`New-Object StreamReader($_.Exception.Response.GetResponseStream())`）在 PowerShell 7 上**永远拿到空串** ——
于是 GitHub 的 `message` 永久丢失。唯一可靠的办法是**别让它抛**：`-SkipHttpErrorCheck`（PS 7）先拿到响应体。

**修法**：

| 文件 | 改动 |
|------|------|
| `scripts/pool-lib.ps1` | `Invoke-GhApi` 改用 `Invoke-WebRequest -SkipHttpErrorCheck`；非 2xx 时把 GitHub 的 `message` 拼进异常：`HTTP 403 Forbidden [/path] Sorry. Your account was suspended`。PS 5.1 无此开关 → 退回 `Invoke-RestMethod`（拿不到 body，但不报错） |
| `scripts/pool-coordinator.ps1` | **把「派发失败」并进该账号的巡检 `note`** —— 之前派发失败只打日志，面板完全看不到（acc-4 的 422 藏了一整天） |
| `workbench/static/app.js` | `explainTokenError` 新增**账号级**故障识别：`account was suspended` → 「账号被停用」、`Actions has been disabled for this user` → 「Actions 被禁用」、422 → 「派发被拒 · 422」；`tokenStateBadge` 在 `token_state=ok` 但 `note` 含「派发失败」时显示「凭证正常 · 派发失败」（红）；备注行不再要求 `token_state != ok` |

**验证**：`selftest.py` **569 PASS / 0 FAIL**（本批 T484–T489）；`pool-lib.ps1` / `pool-coordinator.ps1`
用 `[Parser]::ParseFile` 语法校验通过；**dot-source 真文件实测**：成功路径返回 `PSCustomObject`，
错误路径异常消息 = `HTTP 401 Unauthorized [/user] Bad credentials` / `HTTP 404 NotFound [...] Not Found`。

**这次真机探针的实际产出**（只读探测，用完即删）：

| 账号 | GitHub 原话 | 结论 |
|------|------------|------|
| acc-1 `yc1966asgf` | `{"message":"Sorry. Your account was suspended"}` | **账号被 GitHub 停用** —— 所有 API 403，换 PAT 也没用 |
| acc-4 `code1969sda` | `{"message":"Actions has been disabled for this user."}` | **该账号的 Actions 被禁用** —— PAT 有效、仓库可读、workflow 是 `active`，但派发一律 422 |

### 24. 账号调度：hub 账号降为「兜底」+ 前端「隐藏失效账号」（v1.6.8）

**需求**：① 降低 hub 账号（`3465125540` / acc-3）的使用频率，把它当兜底机器 —— **只在其余所有账号都用不了时才派它**；
② 加一个「隐藏失效账号」按钮，点了把失效账号的**账号信息 + 运行日志**一起藏起来。

#### ① 兜底梯队（`reserve`）

账号项加一个 `reserve: true` 即标记为兜底（本仓库给 acc-3 标了）。`Get-PoolPlan` 的候选顺序变成**两梯队**：

```
第一梯队（reserve != true）  →  兜底梯队（reserve == true）  →  都没有 → 不派
```

| 场景 | 结果 |
|------|------|
| 第一梯队够用 | **完全不碰兜底账号** |
| 第一梯队全被占用/不可用 | 才启用兜底账号 |
| 账号项没写 `reserve`（老配置） | 全部算第一梯队，**行为与旧版完全一致** |

**关键配套**：新增 `-ExcludeOwners`，协调器把「**已知不可用**」的账号（上一轮 `token_state` = `query_failed`/`missing`，
或 `note` 里带「派发失败」）排除在候选之外。没有这一步，兜底规则会被死账号架空 ——
acc-1（账号被停用）/ acc-4（Actions 被禁用）虽然永远派发失败，却**占着第一梯队的候选位**，
协调器每轮都先试它们、**永远轮不到能用的那个**，池子就卡在 1/2 台补不上。
排除列表**只取上一轮** ⇒ 天然一轮自愈：账号恢复后下一轮就不再被跳过。

**验证**（本机 PS 7 直接 dot-source `pool-lib.ps1` 跑 `Get-PoolPlan`，7 个场景全过）：

| 场景 | 产出 |
|------|------|
| 排除 acc-1/acc-4 + 目标 2 台 | `acc-5, acc-3` ← 死账号不再占位，兜底才补位 |
| 只有 acc-3(兜底)+acc-5，目标 1 台 | `acc-5` ← **兜底不被优先** |
| 第一梯队全被排除 | `acc-3` ← 兜底只在此时启用 |
| 第一梯队够用 | `acc-1, acc-5` ← 完全不碰兜底 |
| 老配置（无 `reserve` 字段） | 顺序不变，行为与旧版一致 |

#### ② 「隐藏失效账号」按钮

「失效」的判定（`isAccountDead()`，只影响**显示**，不改任何数据）：

| 判定项 | 说明 |
|--------|------|
| 模板占位 | `REPLACE_OWNER_N` |
| 已停用 | `enabled: false` |
| 凭证坏 | `token_state` = `query_failed` / `missing` |
| 派发失败 | 协调器巡检 `note` 里带「派发失败」（如 acc-4 的 422） |

点一下同时隐藏：**账号管理表**、**运行日志的账号分组**、**运行日志的账号筛选 tab**。
开关状态记在本机浏览器 `localStorage["wb.hideDeadAccounts"]`（刷新后保持，`try/catch` 兜住隐私模式）；
按钮文案随状态在「隐藏失效账号 ↔ 显示失效账号」之间切换；统计行会写「已隐藏 N 个失效账号」，免得以为账号变少了。

> **诚实边界**：① 判定完全基于协调器发布的巡检结果 —— acc-4 的「派发失败」要**等协调器下一轮跑过**
> （约 3 小时，或点「立即巡检」）才会写进 `note`，在那之前它不会被判定为失效。
> ② 兜底账号**不改变 `target_machines` 语义**：目标 2 台、而第一梯队只有 1 个可用账号时，兜底账号仍会被派去凑第 2 台
> —— 这正是「其余机器都不可用」的情形。③ 本次**没动用户的 `enabled` 开关**：acc-1/acc-4 仍是启用状态，
> 只是被 `-ExcludeOwners` 动态跳过（账号恢复即自动回归）。

### 25. 机器运行实况「显示不同步」：实时纠偏扩到所有可读账号（v1.6.9）

**现象**（瑀子 2026-10-05）：机器运行实况里 acc-5 那行写着

```
code19698fgh / 池内机器 · primary / 100.126.147.85 / 运行中
Actions job 运行中 · run 37269211081 · 自 2026/10/5-13:45
```

可它的 run **早已 cancelled**（GitHub：`completed/cancelled`，14:24:38Z 结束），Tailscale 节点也早已离线。

**根因**：实时纠偏**只认 hub 账号**。`hub_live_probe()` / `live_runs_by_id()` 第一件事就是
`if owner != CONFIG["repo"] 的 owner: return None` —— 于是 acc-5 这种账号只能信协调器发布的
**pool-state 快照**；而协调器 cron 常被 GitHub 延迟数小时（这次快照 6 小时前），
快照里那个 run 当然还写着 `in_progress`。

**关键点**：acc-5 的 fork 是**公开仓库**，工作台的 token（甚至匿名）本来就读得到它的 actions runs
—— 也就是说这行**本来就能实时核对**，只是代码把它挡在了门外。

**修法**：

| 改动 | 说明 |
|------|------|
| 新增 `_account_runs(owner, repo)` | 直查**任意账号**仓库的 workflow runs（60 秒缓存）；读不到（私有 fork / 无权限 / 离线）返回 `None`，调用方退回 pool-state |
| 新增 `_account_live_rows(owner, repo)` | hub 走已有的 runs 缓存（零额外请求）；其余账号走 `_account_runs` |
| `hub_live_probe` → **`account_live_probe`** | 名字不再骗人：能读到的账号都实时探测（「账号面板」的在跑台数 / 最近 run 一起受益） |
| `live_runs_by_id` 改走 `_account_live_rows` | 「机器运行实况」的池内机器行也按实时 run 纠偏 |
| 池行新增 `state_age_human` / `state_stale` | 快照年龄（人话）+ 「是否已陈旧到不能当准」（> 90 分钟） |

**兜底（读不到的账号）**：私有 fork / 无权限时仍然只能信快照 —— 但**不再硬说「运行中」**：
快照超过 `POOL_SNAPSHOT_STALE_SECS`（90 分钟）就把徽标降级成 **「运行中 · 未核实」**（黄），
详情行摊出「快照 6.0 小时前」，tooltip 说清「本机读不到该账号的 fork，无法实时核对」。

**验证**：`selftest.py` **594 PASS / 0 FAIL**（本批 T504–T511）；另**导入改后的 server.py 跑真实代码路径**：

| 检查 | 结果 |
|------|------|
| `account_live_probe('code19698fgh')` | `alive=0 running=0`，`last_run=37269211081 completed/cancelled` ← 实时读到了 |
| `account_live_probe('3465125540')`（hub） | `alive=1 running=1`，`last_run=37310199415 in_progress` |
| `account_live_probe('yc1966asgf')` / `('code1969sda')` | `None`（读不到 → 退回快照，前端标「未核实」） |
| `pool_machine_rows(...)` 的 acc-5 行 | `machine_state=ended`、`run_source=live`、`stale=False` ← **不再是「运行中」** |
| 前端 `poolOnlyRow()` 5 个场景 | 10 项断言全过（陈旧快照→未核实 / 新鲜快照→运行中 / live→不提快照 / live 已结束→已结束 / 陈旧已结束→已结束） |

> **诚实边界**：① 私有 fork（如 acc-4）本机读不到 runs，仍只能信快照 —— 但界面会如实标「未核实 + 快照年龄」，
> 不再假装知道。② 快照阈值取 90 分钟：协调器正常节奏约 3 小时，所以**私有账号**的池行通常会带「未核实」
> 标记 —— 这是事实，不是 bug。③ 本批只改**显示与核对口径**，不改协调器、不改池状态。

### 26. `startup_failure`：派发「成功」但机器起不来 —— 也要算「已知不可用」（v1.6.10）

**现象**（2026-10-08 查 acc-4/acc-5 健康时发现）：acc-5 的账号面板显示「**凭证正常** · 在跑 0 台」，
看着像个好账号 —— 实际上它从 **2026-10-06T06:31Z 起连续 8 次**都没起来过机器。

**真机取证**：

| 观察 | 值 |
|------|-----|
| acc-5 的 run `37712372578` | `status=completed`、**`conclusion=startup_failure`**、`jobs=0`、created→updated 只差 **1 秒** |
| 协调器派发 acc-5 的返回 | **HTTP 204（成功）** —— 所以协调器记的是「已派发」 |
| 同一个 commit（`6e268a4`）派给 acc-2 | `in_progress` —— **真的起来了** |
| run 页面的 Annotations | `Error: Please verify your email address to run GitHub Actions workflows.` |

**根因**：acc-5 **账号的邮箱未验证** → GitHub 收下 dispatch、也建了 run，但**拒绝构建 job**（0 jobs），
1 秒内以 `startup_failure` 结束。**这是账号级故障，跟 PAT / 仓库 / workflow 文件都无关。**

**为什么之前看不见**：`startup_failure` **不留「派发失败」痕迹**（dispatch 是 204），
而 v1.6.8 的「已知不可用」只认 `token_state` 坏 + note 里的「派发失败」→ 它逃过了检测，
协调器每轮都白派一次；前端 `runStateKind()` 也没把它算进 `bad`，面板渲染成灰色「无结论」。

**修法**：

| 改动 | 说明 |
|------|------|
| `pool-coordinator.ps1` | 「已知不可用」新增一条：上一轮 `last_run.conclusion == 'startup_failure'` → 本轮不参与候选 |
| `pool-coordinator.ps1` | 同时把原因写进该账号本轮的巡检 `note`（面板才看得见「为什么出不了机器」） |
| `app.js` `runStateKind()` | `startup_failure` → **红色**（原来落进 `mute` 灰，看着像没事） |
| `app.js` `isAccountDead()` | 也认 `last_run.state == 'startup_failure'`（v1.6.12 补）—— 否则「隐藏失效账号」按钮**藏不掉它**：
v1.6.10 只把原因写进 note，而 note 文案里没有「派发失败」四个字，按钮的判定条件匹配不上 |

**验证**：`selftest.py` **607 PASS / 0 FAIL**（本批 T512–T515）；另**用真文件跑了一次真实 dry-run**
（`pool-coordinator.ps1 -DryRun` + 构造的上一轮状态）：

```
[pool] 已知不可用（本轮不参与候选）：yc1966asgf, code1969sda, code19698fgh   ← 三类故障全被识别
[pool] 决策：alive=0/2 plan=2  primary候选=code09101
[pool] [dry-run] 派发 → acc-2 (code09101)  role=primary  reason=fill        ← 正确跳过 acc-5
[pool] [dry-run] 派发 → acc-3 (3465125540)  role=standby  reason=fill
```
输出状态里 acc-5 的 note 也确实带上了「最近一次 run 启动失败（startup_failure）…」。

**本次 4 个账号的健康结论**（顺带记录，方法见 §22/§23）：

| 账号 | 状态 | 原因 |
|------|------|------|
| acc-1 `yc1966asgf` | 🔴 已停用（`enabled: false`） | 账号被 GitHub 停用（`Sorry. Your account was suspended`） |
| acc-2 `code09101` | 🟢 **健康** | 新加账号；dispatch 204 → run **`in_progress`**（真起来了） |
| acc-3 `3465125540` | 🟢 健康（兜底 reserve） | hub 账号 |
| acc-4 `code1969sda` | 🔴 不能用 | dispatch **422**：`Actions has been disabled for this user.`；历史 run **0 条** |
| acc-5 `code19698fgh` | 🔴 不能用 | **邮箱未验证** → `startup_failure`（见上） |

> **acc-5 的修法（1 分钟）**：用该账号登录 → `https://github.com/settings/emails` 完成邮箱验证 → Actions 立刻恢复。
> **acc-4 的修法**：GitHub 在**账号级**禁用了它的 Actions，需去该账号的 Billing/设置排查或联系 GitHub 支持。

### 27. 「GitHub 账号管理」排版优化：标题不换行 + 列宽写死 + 两行节奏（v1.6.11）

**现象**（2026-10-08 截图）：这张卡在宽屏下是 `span-5`（约 700px），5 列挤在里面，露出三个毛病：

| 毛病 | 原因 |
|------|------|
| 标题被挤成「账号管 / 理」 | `.card-head h2` 没 `nowrap`，被同行的概览文案挤窄 |
| 「＋ 新增」被挤到第二行 | 概览文案（「5 个账号 · 已隐藏 1 个失效账号 · 监测数据 2026/10/8-09:15 北京（raw）」）跟两个按钮一起塞在 `head-right` 里，`flex-wrap` 只好换行 |
| 「实时监测」列忽宽忽窄、同一列在不同行之间上下跳 | `auto` 表格布局，列宽随内容抖动；该列内容「凭证 + 在跑 N 台 + run 徽标 + 时间 + 实时」又是一行流式排布 |

**修法**（三处，都是「让它别挤」）：

| 改动 | 说明 |
|------|------|
| `index.html` | 概览从 `head-right` 挪到**独占一行的 `.card-sub`**（与「机器运行实况」同一节奏）—— 头部只剩标题 + 两个按钮 |
| `index.html` | 账号表加 `class="tbl tbl-accounts"` + `<colgroup>`：账号 23% / Secret 17% / 角色 13% / **实时监测 35%** / 启用 12% |
| `styles.css` | `.card-accounts .card-head h2 { white-space: nowrap; }` + `.tbl-accounts { table-layout: fixed; }` + 上表列宽 + `.tbl-accounts tbody tr { height: 62px; }` |
| `styles.css` | 「实时监测」列由 `flex-wrap` 一行流改成**块级两行**（`.mon-cell{display:block}` + `.mon-line`）：① 凭证 + 在跑/排队　② 最近 run + 数据来源 |
| `app.js` | 账号列也改成两行：① 真实账号名（`nowrap`，不再被徽标挤成两行）② `代号 acc-N` + 「兜底」徽标（`.acc-sub`） |

**验证**：`selftest.py` **613 PASS / 0 FAIL**（本批 T516–T521，另修了两条因标记变化而过期的旧断言 T207/T477）；
另用 Node 跑**真实** `renderAccounts()`（真实 `/api/accounts` 数据 + 桩 DOM），逐行检查产出的 HTML：

```
行1 账号=yc1966asgf    代号 acc-1                    mon-line 数=2
行2 账号=3465125540    代号 acc-3 兜底                mon-line 数=2
行3 账号=code1969sda   代号 acc-4                    mon-line 数=2
行4 账号=code19698fgh  代号 acc-5                    mon-line 数=2
行5 账号=code09101     代号 acc-2                    mon-line 数=2
```
断言全过：账号名在 `.nowrap` 里 / 代号+兜底在 `.acc-sub` 里 / 「兜底」只出现在 reserve 那一行 / 每行 2 个 `.mon-line`。

> **只改排版**：数据口径、字段、交互一律没动；`.card-accounts` 的 `span-5 → span-12` 断点（≤1720px 占整行）保持不变。

### 28. 新账号「Secret 已配置却报缺 Secret」：协调器 env 漏列（v1.6.13）

**现象**（2026-10-08 用户贴 acc-8 那行）：同一行里两个口径打架 ——

```
账号 code14201 (acc-8)   Secret 列：已配置 POOL_TOKEN_8   实时监测列：缺 Secret
                        备注：Secret POOL_TOKEN_8 未配置
```

**真机取证**：Secret 列没错、实时监测也没错，**是协调器根本没拿到那个 Secret 的值**：

| 检查 | 结果 |
|------|------|
| hub 的 Secret 列表 | `POOL_TOKEN_8` **存在**（2026-10-08T06:28:39Z 建的） |
| `code14201/cloud-rdp` | **存在**（public fork，02:42 推过） |
| 协调器日志 | `账号 acc-8 (code14201)：跳过（Secret POOL_TOKEN_8 未配置）` |
| **`pool-coordinator.yml` 的 `env:`** | **只列到 `POOL_TOKEN_6`** ← **元凶** |

`Get-PoolAccountToken` 先读 `$env:POOL_TOKEN_8`、再读 `POOL_TOKENS`（JSON）。env 里没列这个 Secret 名，
**GitHub 就不会把它注入 job 环境** → 脚本只看到空值 → 报「未配置」。
**漏列 = 等于没配** —— 而界面看不出这一点（Secret 列表里它确实在）。

**修法**：

| 改动 | 说明 |
|------|------|
| `pool-coordinator.yml` | `env:` 从 `POOL_TOKEN_1..6` **补到 `POOL_TOKEN_1..12`**（对**不存在**的 secret 引用，GitHub 给空串、不报错 → 多列是安全的余量，以后加账号不必再改 workflow） |
| `app.js` | `tokenStateBadge()` 收 `secretPresent`：Secret 名**存在**但协调器取不到值 → 徽标「**Secret 未生效**」（不再是笼统的「缺 Secret」）+ tooltip 指向 `pool-coordinator.yml` |
| `app.js` | 备注给准确指引：`Secret「POOL_TOKEN_8」在 hub 里存在，但协调器取不到它的值 —— 最常见是 pool-coordinator.yml 的 env: 没列这个 Secret 名` |
| `selftest.py` | **新增防回归断言 T523**：`pool-coordinator.yml` 的 env **必须覆盖 pool-config 里每一个 `token_secret`** —— 这类 bug 从此不可能再溜过去 |

**顺带处理**：`acc-7 (code1420)` **owner 写错了**（`code1420/cloud-rdp` = 404，与 acc-8 的 `code14201` 撞车，
疑似笔误留下的幽灵账号）→ **已从 pool-config 移除**（本仓库工作台没有「删除账号」入口，直接改的 `scripts/pool-config.json`）。

**验证**：`selftest.py` **620 PASS / 0 FAIL**（本批 T523–T526，另修两条因函数签名变化而过期的旧断言 T481/T521）；
`pool-coordinator.yml` 过 `yaml.safe_load` 校验；Node 跑**真实** `renderAccounts()`（真实 `/api/accounts`）：
acc-8 徽标 = 「Secret 未生效」+ 备注含 `pool-coordinator.yml`，acc-3 仍是「凭证正常」且不误标。

> **生效**：`pool-coordinator.yml` 是 GitHub 侧 → **下一轮协调器 run 生效**（之后 acc-8 应变成 `token_state=ok`）；
> 前端改动 → **浏览器刷新即生效**。

## 五、目录结构

```
cloud-rdp/
├── .github/workflows/windows-rdp.yml   # 主工作流（26 步，见下表）
├── workbench/                          # 【新】GitHub 虚拟机管理工作台（本机仪表盘，Python 标准库零依赖）
│   ├── server.py                       #   后端：HTTP 服务 + 全部 API
│   ├── selftest.py                     #   离线自测（620 项）
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
    ├── userprofile-lib.ps1             # 【新】用户配置文件预创建（显式 -LoadUserProfile + ProfileList 兜底；修「还原后用户数据全丢」）
    ├── watchdog-lib.ps1                # 【新】保命共享库：GitHub 可达性探测 / 主机体征 / Defender 排除 / 有限超时 / 网络自愈 / 连接看门狗
    ├── account-lib.ps1                 # 【新】账户守卫：隐藏非 RDP 账户（登录界面 SpecialAccounts + profile 目录 +h+s）+ 白名单断言（只留 a）
    ├── session-lib.ps1                 # 【新】会话归属：控制台是谁（UU远程 连的就是它）+ 桌面「切到 UU远程」+ 无感自动交接任务
    ├── session-handover.ps1            # 【新】把当前会话交给控制台（tscon /dest:console，只断开不 logoff）；-Auto = 无感自动
    ├── conn-watchdog.ps1               # 【新】连接看门狗子进程：每分钟探一次，连续不可达即分级自愈 + 打印判定
    ├── pool-config.json                # 【新】账号池配置（无密钥：hub/账号/PAT-Secret 名）
    ├── pool-lib.ps1                    # 【新】账号池公共库：在跑机发现 / 决策 / 角色 / 状态
    ├── pool-coordinator.ps1            # 【新】hub 协调器：补机 + 轮换 + 发布权威角色
    └── quota-report.ps1                # Actions 额度估算与告警
```

工作流 26 步。**0d 之后就能连**，其余在后台继续跑：

| # | 步骤 | 说明 |
|---|------|------|
| 0 | 拉仓库 | `actions/checkout` |
| **0p** | **跟随上游 hub 同步脚本（fork 自愈）** | 从 hub 仓库下 `scripts/` 覆盖本机脚本（`/MIR`）—— **老 fork 不必手点 Sync 也能拿到最新逻辑**。⚠️ 只覆盖 `scripts/`、**覆盖不到 `.github/workflows/`**（Actions 用的是触发 commit 里的 workflow），所以 workflow 内联的保命参数对老 fork 不生效（acc-5 事故，见 §17）。本步 fail-soft、末尾 `exit 0`，robocopy 退出码已归一化（不再误报 `exit 1`）；顺带 SHA256 比对 workflow 是否与 hub 漂移 |
| **0a** | 记录 job 起点 + 开 RDP + **关防火墙** + **加 Defender 排除项** | 尽早写 `_state\job-start.txt`（供 ETA / 耗时计算）；顺手把 `watchdog-lib.ps1` 的 `Enable-RdpAvExclusions` 调了 —— 后面第 7/8 步要落地 ≈1.8 万个小文件，**必须**在重 IO 之前把实时扫描摘掉（见 §11） |
| **0b** | 建管理员账号 + 数据目录 + 桌面快捷方式 | 数据目录 `D:\a\cloud-rdp`（**会排除其中的仓库 checkout**） |
| **0b2** | **会话归属校正 + 装「切到 UU远程」快捷方式 + 无感自动交接** | `session-lib.ps1`：诊断当前控制台会话归属 → 写 `CONSOLE_OWNER`；一次装齐 ① SYSTEM 任务 `CloudRDP-UUHandover` + ② 公共桌面「切到 UU远程」+ ③ 无感自动任务 `CloudRDP-UUAuto`（开机 + 每 60s，仅切**没被 RDP 连着**的 `a` 会话，见 §16） |
| **0c** | 安装并连接 Tailscale | ← **IP 在这里产生**，并记录「可连时刻」。`tailscale up` 带 **`--accept-dns=false`**，避免 VPN 接管系统 DNS 把 runner 自己的长轮询也拽进隧道（见 §11） |
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
| **12b** | **中文语言包收尾核对** | `setup-chinese.ps1 -CheckOnly`：0f 转后台的语言包若已装完，这里补报一次；**保活循环**每 10 分钟也补查一次 |
| **13** | ⭐ **环境就绪汇总（ENV READY）** | 初始化完成；含全部状态行（数据恢复 / 整机还原 / **中文语言包** / **Edge 与 WorkBuddy 用户数据取证（`USERDATA_RESTORE`）** / **UU远程 设备身份（`UU_RESTORE`）** / **Edge 登录态（`EDGE_CRYPT`：`os_crypt` 加密密钥能否解开）** / **失效快捷方式** / **邮件投递结果** / 快照一致性）+ 总耗时；桌面标记改名 `_CloudRDP_READY.txt` |
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
| 开机后桌面是空的 | `SNAPSHOT_USER_PRERESTORE=SKIPPED`（预创建 profile 失败） | **已修**（`userprofile-lib.ps1` 显式 `-LoadUserProfile` + ProfileList 兜底）。若仍出现：看 `D:\cloudrdp-sys\_state\user-restore.log`；登录任务会兜底重试，公共桌面会有失败标记 |
| Edge 登录态没了 | cookie/密码由 DPAPI 加密，跨机解不开（日志 `EDGE_CRYPT=BROKEN`） | 正常。用 Edge 账号同步恢复；历史/书签/偏好/`Local Storage` 应该都在 |
| Edge 数据**整个**没了（连历史/书签都没有） | profile 没预创建成功 → 用户级还原被整段跳过（`SNAPSHOT_USER_PRERESTORE=SKIPPED`、`EDGE_RESTORE: MISSING`） | **已修**：`userprofile-lib.ps1` 显式 `-LoadUserProfile` + `ProfileList` 兜底，失败计入 `SNAPSHOT_STATUS=PARTIAL`；看 `D:\cloudrdp-sys\_state\user-restore.log` |
| **UU远程 每次都当新设备 / 反复要求登录或创建账号** | **根因**：UU远程 的设备身份在 `C:\ProgramData\Netease\GameViewer`（`deviceId`/`uuid`/协助码）与 `%LOCALAPPDATA%\GameViewer`（`setting.ini`）—— 前者是**机器级**路径，不在以 `%RDPUSERPROFILE%` 为中心的 `files.dirs` 里，于是每轮新机器都被当成全新设备 | **已修**：两处都进 `files.dirs` + `files.noExcludeDirs`，`programs.dataGlobs` 再兜一层，并加 `restore.userDataTargets` 校验 → ENV READY 打印 `UU远程设备 : OK/PARTIAL/MISSING`（详见第四节 §12）。⚠️ 协助码是 DPAPI 密文、跨机解不开会被重新生成（同 Edge 的 `os_crypt`），想彻底免掉请**登录 UU 账号** |
| 云机上看到一个 `runneradmin` 账户 | 它是 **GitHub 托管 runner 自己的 Windows 账户**（镜像烘焙自带、本次 job 的 runner agent 正以它身份跑），**不是 UU远程 / 流程建的**（全仓零账户创建代码，只建 `a`） | **已处理**：删不掉（删了 job 当场死），但已从「登录界面 + 资源管理器」隐藏 → 用户视角只剩 `a`。ENV READY 会打 `账户 : 唯一可见 = a  已隐藏 runneradmin`；有未知账户会黄字告警（详见第四节 §14） |
| **机器实况显示「运行中」，但账号面板显示「已结束」**（信息同步异常） | 机器实况原来直接信协调器每几小时发一次的 `pool-state` 快照；协调器抓快照时 run 还在 `in_progress`、之后 run 结束而协调器还没重跑 → 快照口径滞后 | **已修**：机器实况对能实时查的账号（hub）按 GitHub 实时 run 纠偏，并标 `run_source=live/pool-state`，两个面板口径一致（详见第四节 §15） |
| **机器实况主机列显示「账号未知」，但机器明明在线** | 归属要读机器上的 `_state\pool-info.txt` 或 runner 工作区 `D:\a\<repo>\<repo>\.git\config`，**两条都走 SMB**；机器侧 SMB 栈还没起来（`net use` 报**系统错误 67「找不到网络名」**、`net view` 报 1702）就都读不到。旧代码还有两个坑：SMB 预鉴权失败也把 IP **永久拉黑**、`job_tailscale_ip` 把**空结果缓存 1 小时** → 机器后来就绪了也补不上 | **已修**：SMB 预鉴权**成功才**拉黑、失败 60 秒后自动重试（点「刷新」立刻重试一次）；空 IP 结果只缓存 60 秒；再加**来源③**「账号池反查 IP → 账号」兜底（只认 `in_progress` 的 run）。tooltip 会说清原因。详见第四节 §18 |
| **点「刷新」后时间戳不动 / 一直「后台刷新中」** | `overview_seconds=20` 秒小于快照**实测构建耗时**（13~49 秒）→ 快照一建出来就已过期，每个请求都触发重建；且 `stale` 被误写成「比 TTL 老」而非「真在重建」。另：请求在途时点刷新会被 `if (BUSY) return` **静默丢掉** | **已修**：TTL 取 `max(配置, 构建耗时 + 5 秒)`；`stale` 只表示「有重建在途」；按钮加**禁用 + 「刷新中…」**进度，时间戳显示「更新于 …（N 秒前）」，在途点击会**排队补发**。详见第四节 §18 |
| **概览「恢复异常」显示 N 数据，但机器其实没失败** | 恢复失败标记文件（`_RESTORE_FAILED.txt` / `_RESTORE_EMPTY.txt`）躺在数据目录根，会**随数据目录同步到 139、再被还原到别的机器** → 一台机器的失败标记被所有机器继承；且工作台回退读标记时只测存在、不看时间，几天前的老标记也照算 | **已修**：数据目录同步**排除** `_RESTORE_*.txt`（断源头）；回退读标记时解析时间，**旧格式 / 早于本机本次开机的**标为陈旧，不计入异常，机器表显示灰色「旧标记·已忽略」。详见第四节 §19 |
| **界面上账号显示成 `acc-1 / acc-3`，看不出是谁** | 前端多处直接渲染了账号池的内部代号 `id`（`acc-N`），而不是 GitHub 账号名 | **v1.6.5 起**：全站统一 `accLabel()` —— 显示真实账号名（`owner`），名称缺失时依次兜底到「代号 acc-N」→「未命名账号」；代号降级到 tooltip / 小字，仍可与 `pool-config.json` 对照。详见第四节 §21 |
| **账号「凭证」列显示「查询失败」+ 一串 .NET 异常（`403 (Forbidden)`）** | 该账号的 PAT（如 `POOL_TOKEN_1`）**失效**了 —— 协调器用它读 runs / 同步 fork / 派发机器全被 403 拒绝；面板原来把 .NET 异常原样摊出来 | **v1.6.6 起**：翻译成「凭证被拒 · 403」并给出行动建议（重新生成 PAT → 更新该 Secret）；401/404/429 各有对应文案，原始串降级到 tooltip。详见第四节 §22 |
| **账号面板只显示 `403 (Forbidden)` / `422`，看不到原因** | `Invoke-RestMethod` 抛错时**响应体已被 dispose**，catch 里 `GetResponseStream()` 永远读到空串 → GitHub 的 `message` 永久丢失；且「派发失败」原来不写进池状态，面板根本看不到 | **v1.6.7 起**：`Invoke-GhApi` 改用 `-SkipHttpErrorCheck` 保住响应体并把 message 拼进异常；协调器把「派发失败」写进账号 note；面板识别「账号被停用 / Actions 被禁用 / 派发被拒 · 422」。详见第四节 §23 |
| **想让某个账号少用点（当兜底）、或界面上一堆失效账号太吵** | 原来候选顺序就是 pool-config 里的账号顺序，hub 账号总被优先；失效账号既占候选位又占屏幕 | **v1.6.8 起**：账号项加 `"reserve": true` 即降为**兜底**（只在第一梯队全不可用时才派）；协调器同时排除「已知不可用」账号（凭证坏/派发失败），死账号不再占位。前端新增「**隐藏失效账号**」按钮，一键藏掉失效账号的账号表 + 运行日志。详见第四节 §24 |
| **机器运行实况显示「运行中」，但机器其实早没了** | 池内机器行的状态来自协调器发布的 pool-state 快照，而实时纠偏原来**只认 hub 账号**；其余账号（哪怕 fork 是公开的、本机明明读得到）一律退回快照 —— 协调器 cron 又常被延迟数小时 | **v1.6.9 起**：实时纠偏扩到**所有读得到的账号**（`_account_runs` 直查各 fork 的 runs）；读不到的（私有 fork）把徽标降级成「运行中 · 未核实」并在详情行摊出快照年龄。详见第四节 §25 |
| **账号「凭证正常」但机器一直起不来（run 显示 `startup_failure`）** | GitHub 收下了 dispatch（返回 204）但**没建出 job** —— 常见于**该账号邮箱未验证**、该账号 Actions 被禁用、账单/额度问题。这类故障不留「派发失败」痕迹，原来的「已知不可用」检测看不见 | **v1.6.10 起**：`last_run.conclusion == startup_failure` 也纳入「已知不可用」（协调器不再白派），并把原因写进账号巡检 note；前端把 `startup_failure` 渲染成红色。**修法**：去该账号 `github.com/settings/emails` 验证邮箱（run 页面的 Annotations 会写明原因）。详见第四节 §26 |
| **新加的账号显示「缺 Secret」，但 Secret 列明明写着「已配置」** | `pool-coordinator.yml` 的 `env:` 是一份**写死的 Secret 名单**（原来只到 `POOL_TOKEN_6`）—— 新账号的 Secret 名没列进去，GitHub 就不注入，脚本只看到空值 → 报「未配置」。**漏列 = 等于没配** | **v1.6.13 起**：env 补到 `POOL_TOKEN_12`（对不存在的 secret 引用给空串、不报错）；面板改说「**Secret 未生效**」并直接指向 `pool-coordinator.yml`；selftest 新增断言，**要求 env 覆盖 pool-config 里每一个 token_secret**。详见第四节 §28 |
| 快照推送很慢 | 体积不设上限 + 139 约 0.45 MB/s | 看日志 `SNAPSHOT_ETA_MIN`；大目录用 `copy` 可续传，下次接着传 |
| **想让机器跑满 4 小时就自动换新机（别断档）** | 单 job 硬上限 6 小时，人工盯表容易漏 | **v1.6.4 起内置「自动接力」**：任一台在跑机器运行时长 ≥ `auto_start.uptime_hours`（默认 4 小时）→ 自动派发 1 台新机器。默认**关**（耗 Actions 分钟数），`config.json` 写 `{"auto_start":{"enabled":true}}` 重启即开；去重 = 同机只触发一次 + 冷却 30 分钟 + 每小时上限 4 台。只想看会不会触发：`GET /api/auto-start?dry=1`。详见第四节 §20 |
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
