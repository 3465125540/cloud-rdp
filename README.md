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
| 频率 | 私有仓库免费额度 2,000 分钟/月，Windows **2×** → 约 **4 次 4 小时会话/月** |
| 触发 | **手动**（Actions → Run workflow），无定时任务 |
| 数据 | 存于 139 云盘，开机拉取、运行中每 10 分钟同步、关机前全量同步 |
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

1. 仓库顶部 → **Actions** → 左侧选 **Windows Cloud RDP** → **Run workflow**
2. 等约 5–8 分钟，展开 **8. 打印连接信息** 步骤，记下 **Tailscale IP**
3. 也可在 https://login.tailscale.com/admin/machines 看到 `github-rdp-server` 设备

### 3. 本地连接

1. **前提**：本地电脑已安装 Tailscale 并登录**同一账号**
2. `Win + R` → `mstsc` → 计算机填 **Tailscale IP** → 连接
3. 用户名 `NvdAdmin`，密码为 workflow 里写死的 `RDP_PASSWORD`（默认 `Rdp@2026#Nvd`）
4. 证书警告点「是/继续」

### 4. 数据在哪里 / 自动恢复

- 云主机里用 **`C:\data`** 这个目录存数据（**公共桌面已放 `CloudData` 快捷方式**，双击即达）
- **开机自动恢复**：每次启动自动把 139 云盘的 `/CloudRDP` 拉回 `C:\data`
- 运行中每 10 分钟推送到 139 云盘；关闭会话后还会做一次全量推送
- 恢复结果会显示在 **「8. 打印连接信息」** 步骤里：

  | 状态 | 含义 |
  |------|------|
  | `OK` | 恢复成功（日志打印文件数 / 大小） |
  | `EMPTY` | 远端还没有数据（首次运行正常） |
  | `FAILED` | 恢复失败 —— 多半是 139 Authorization 过期；`C:\data` 是空的，**别在上面存重要东西** |

- 恢复失败时会在 `C:\data` 留一个 `_RESTORE_FAILED.txt` 标记，并**红色高亮**警告
- 恢复失败**不会**挡住 RDP 启动（脚本永远返回 0），保证机器始终可用

---

## 五、目录结构

```
cloud-rdp/
├── .github/workflows/windows-rdp.yml   # 主工作流
└── scripts/
    ├── setup-rclone.ps1                # 安装并配置 rclone
    ├── setup-alist.ps1                 # 部署 AList，挂载 139 云盘
    ├── sync-down.ps1                   # 139 → C:\data
    └── sync-up.ps1                     # C:\data → 139
```

139 云盘内的存放位置：`CloudRDP/`（AList 挂载点 `/cloudrdp` 下的子目录）。

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

---

## 七、风险声明

- **非官方用途**：用 GitHub Actions 跑个人云桌面不符合其服务条款，长期使用可能被限流/封号。本仓库默认**私有**以降低暴露面，但**无法保证账号安全**。
- **不要存重要/隐私数据**：数据经 AList 非官方桥接写入 139 云盘，链路不保证稳定与安全。
- **Authorization 约 15 天过期**：需定期手动更新 Secret，否则工作流会在第 6 步失败。
- **额度有限**：私有仓库约 4 次 4 小时会话/月，用完即停。
- **机器是一次性的**：Job 结束即销毁，所有未同步的数据会丢失。

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

推送后别忘了在 **Settings → Secrets and variables → Actions** 配置那 **2 个 Secret**（`TAILSCALE_AUTHKEY`、`ALIST_139_AUTHORIZATION`）。RDP 密码写死在 workflow 里，无需配。
