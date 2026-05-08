# Mia Cloud Relay · Windows 原生部署

在 **Windows Server 2019 / 2022 / 2025** 上以**原生进程**方式部署 Mia 中继。不需要 Docker、WSL、IIS。技术选型、权衡、设计约束见 [design.md](../../openspec/changes/add-windows-relay-deployment/design.md)；签字需求见 [spec.md](../../openspec/changes/add-windows-relay-deployment/specs/relay-deployment-windows/spec.md)。

> 这条路径与 `cloud/` 下的 Linux/Docker 路径**平行**，不互斥。主线 relay 源码对两者完全一致。

---

## 架构一览

```
┌───────────────── Windows Server ─────────────────┐
│  入站 80/443                                     │
│      │                                           │
│      ▼                                           │
│  ┌──────────────┐    127.0.0.1:8000              │
│  │  caddy.exe   │───────────────┐                │
│  │ (MiaCaddy)   │               ▼                │
│  │ ACME + TLS   │       ┌──────────────┐         │
│  └──────────────┘       │ mia-relay.exe│         │
│                         │ (MiaRelay)   │         │
│                         └──────────────┘         │
│                                                   │
│  C:\Program Files\Mia\      ← 二进制              │
│  C:\ProgramData\Mia\config  ← .env (ACL)          │
│  C:\ProgramData\Mia\caddy   ← ACME 证书           │
│  C:\ProgramData\Mia\logs    ← 服务日志            │
└───────────────────────────────────────────────────┘
```

## 目录结构

```
cloud/windows/
├── build/
│   ├── mia-relay.spec          PyInstaller spec（主线模块的隐式 import 清单在此）
│   ├── build-relay.ps1         本机构建 mia-relay.exe
│   └── release.ps1             把 exe + 脚本 + 配置打成 release zip
├── service/
│   ├── mia-relay.xml           WinSW 服务定义（relay）
│   ├── mia-caddy.xml           WinSW 服务定义（caddy）
│   ├── mia-relay-launcher.cmd  注入 .env → exec mia-relay.exe
│   └── mia-caddy-launcher.cmd  注入 .env → exec caddy.exe
├── config/
│   ├── Caddyfile.windows       反代目标=127.0.0.1:8000（与 cloud/Caddyfile 唯一差异）
│   └── env.example             MIA_AUTH_TOKENS / MIA_DOMAIN 模板
├── scripts/
│   ├── common.ps1              共享函数库
│   ├── install.ps1             一键安装
│   ├── upgrade.ps1             就地升级
│   ├── uninstall.ps1           卸载（默认保留 ProgramData）
│   └── status.ps1              只读运维快照
├── dist/                       .gitignore，不入库
│   ├── mia-relay.exe           build-relay.ps1 产出
│   ├── caddy.exe               官方下载
│   └── winsw.exe               官方下载
└── release/                    .gitignore；release.ps1 产出 zip
```

---

## 首次构建（在本机 Windows 11 上）

**前置**：Windows 11 + Python 3.12 在 PATH、git 在 PATH。

### 1) PyInstaller 构建 mia-relay.exe

```powershell
# 在仓库根目录下
powershell -ExecutionPolicy Bypass -File cloud\windows\build\build-relay.ps1
```

脚本会自动建 `cloud\windows\.build-venv\`、装 mia-relay + PyInstaller，产出 `cloud\windows\dist\mia-relay.exe` 并打印 SHA256。首次构建 3–5 分钟，后续增量 <60 秒。

**首次使用前的冒烟**（验证隐式 import 全部就位）：

```powershell
$env:MIA_AUTH_TOKENS = 'dev-local'
$env:MIA_RELAY_PORT  = '8001'
& cloud\windows\dist\mia-relay.exe
# 另开一个 PowerShell：
curl http://127.0.0.1:8001/health
# 期望：{"ok":true}
```

### 2) 下载 Caddy 与 WinSW

- **Caddy for Windows**：<https://caddyserver.com/download> → 选 `windows_amd64`，解压出 `caddy.exe` 放到 `cloud\windows\dist\`。
- **WinSW v3**：<https://github.com/winsw/winsw/releases/latest> → 下载 `WinSW-x64.exe`，**重命名为 `winsw.exe`** 放到 `cloud\windows\dist\`。

两份都是单文件、MIT/Apache 许可证，**不入库**。

### 3) 打 release zip

```powershell
powershell -ExecutionPolicy Bypass -File cloud\windows\build\release.ps1
```

产出 `cloud\windows\release\mia-relay-windows-<git-short-sha>.zip`。

---

## 在目标 Windows Server 上安装

**前置**：

- Windows Server 2019+（已内建 .NET Framework 4.8；Server 2016 需手动装）
- 公网 DNS A/AAAA 记录指向本机公网 IP
- 入站 80/443 在云厂商安全组/网络 ACL 层已放行

### 一键安装

1. 把 release zip 拷到目标机（RDP 剪贴板 / 映射盘 / SMB / U 盘都行）。
2. **关键**：右键 zip → 属性 → 勾 "解除锁定（Unblock）" → 确定。跳过这步的话 PowerShell 脚本会被"来自 Internet"标记阻断。
3. 解压到任意目录，比如 `C:\Temp\mia-relay-windows-abc1234\`。
4. 以**管理员 PowerShell** 在解压目录下运行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\install.ps1
```

脚本会在首次运行时自动打开记事本让你填 `.env`（`MIA_AUTH_TOKENS` 与 `MIA_DOMAIN`），保存并关闭记事本后脚本继续。

### 验证

```powershell
# 本地
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/health
# 期望：StatusCode=200, Content={"ok":true}

# 任意外网主机
curl https://<MIA_DOMAIN>/health
# 期望：HTTP 200, body {"ok":true}, 证书 Issuer=Let's Encrypt
```

首次 HTTPS 请求可能因 ACME 签发耗 30–60 秒。

### 查看状态

```powershell
.\scripts\status.ps1
```

输出两服务状态、监听端口、`/health` 探测、`Mia-*` 防火墙规则、最近 20 行 relay/caddy 日志（其中 ACME 相关行高亮）。

---

## 一键发布（推荐日常升级路径）

两条平行路径，按场景二选一：

| 路径 | 何时用 | 网络流量 | server 依赖 |
|---|---|---|---|
| **A. 源码构建（推荐）** | server 能访问 PyPI + Git | ~KB 级（只推源码） | Python 3.11+、git |
| **B. zip 传输（回退）** | server 离线/无 PyPI | ~20 MB zip 过 scp | 仅 git（可选） |

两条路径由同一入口 `publish-local.ps1` 选择：加 `-BuildOnServer` 走 A，否则走 B。

### 前置条件

- 本机（Win11）：Git for Windows、OpenSSH 客户端（Win10/11 默认已装）在 PATH。**路径 A 不要求本机装 Python**；路径 B 需要本机跑过一次 `build-relay.ps1`。
- 服务端（Windows Server）：
  - 已按上述"首次部署"章节完成一次 `install.ps1`，两服务在 `Running`。
  - 仓库已 clone 到 `C:\Deploy\cloud`（或其他路径，可通过参数指定）。
  - OpenSSH Server 已启用并放行 22 端口，登录账户具备本机管理员权限。
  - **路径 A 额外要求**：server 上装 Python 3.11+、git 在 PATH、出口可访问 PyPI。

### 路径 A：源码构建（本机一条命令）

```powershell
cd D:\Mia
.\cloud\windows\build\publish-local.ps1 -SshTarget Administrator@<server-ip> -BuildOnServer
```

脚本会：

1. `git add cloud/windows/` → `git commit` → `git push`（`-BuildOnServer` 模式下 git push 强制开启，因为 server 要从 origin 拉）
2. `ssh` 远程触发 `scripts\build-on-server.ps1`，在 server 上顺序执行：
   - `git -C C:\Deploy\cloud pull --ff-only`（working tree 脏则跳过）
   - `build-relay.ps1`（产出 `C:\Deploy\cloud\cloud\windows\dist\mia-relay.exe`；首次 3–5 分钟，后续 <60 秒）
   - `upgrade.ps1`（停服 → 换 exe → 启服 → `/health` 探测）
   - `status.ps1`（打印快照）

常用开关：

```powershell
# 升级时顺便升级 caddy.exe：
.\publish-local.ps1 -SshTarget Administrator@<ip> -BuildOnServer -IncludeCaddy

# 顺便刷新 Caddyfile.windows：
.\publish-local.ps1 -SshTarget Administrator@<ip> -BuildOnServer -IncludeCaddyfile

# 彻底清干净 server 端构建缓存重来（依赖漂移时）：
.\publish-local.ps1 -SshTarget Administrator@<ip> -BuildOnServer -Clean

# 指定 SSH 私钥：
.\publish-local.ps1 -SshTarget Administrator@<ip> -BuildOnServer -SshKey C:\Users\me\.ssh\id_ed25519
```

如需手工在 server 上跑（不经本机 SSH 触发）：

```powershell
# 在 server 上管理员 PowerShell：
cd C:\Deploy\cloud\cloud\windows
.\scripts\build-on-server.ps1
```

### 路径 B：zip 传输（本机一条命令）

```powershell
cd D:\Mia
.\cloud\windows\build\publish-local.ps1 -SshTarget Administrator@<server-ip>
```

脚本会：

1. 调 `build-relay.ps1` 重打 `mia-relay.exe`（`-SkipBuild` 可跳过）
2. 调 `release.ps1` 生成 `mia-relay-windows-<sha>.zip`
3. `git add cloud/windows/` → `git commit` → `git push`（`-SkipGitPush` 可跳过）
4. `scp` zip 到 `<server>:C:/Temp/mia-release/`
5. `ssh` 远程触发 `scripts\apply-release.ps1`（`-SkipRemoteApply` 可只传 zip、不触发升级）

常用开关：

```powershell
# 只改脚本/配置，不重建 exe（快得多）：
.\publish-local.ps1 -SshTarget Administrator@<ip> -SkipBuild

# 顺便升级 Caddy 可执行文件：
.\publish-local.ps1 -SshTarget Administrator@<ip> -IncludeCaddy

# 顺便刷新 Caddyfile.windows（路由变更）：
.\publish-local.ps1 -SshTarget Administrator@<ip> -IncludeCaddyfile

# 使用指定 SSH 私钥：
.\publish-local.ps1 -SshTarget Administrator@<ip> -SshKey C:\Users\me\.ssh\id_ed25519

# 只出 zip，不推、不升级（冒烟 / 离线环境）：
.\publish-local.ps1 -SkipShip
```

服务端 `apply-release.ps1` 被远程触发时等同于：

1. `git -C C:\Deploy\cloud pull --ff-only`（working tree 脏则跳过，避免覆盖本地改动）
2. `Expand-Archive <zip>` → `%TEMP%\mia-release\<zip-base>\`
3. 把解压出来的 `mia-relay.exe` / `caddy.exe` / `winsw.exe` 复制到 `C:\Deploy\cloud\cloud\windows\dist\`
4. 调 `scripts\upgrade.ps1`（`-IncludeCaddy` / `-IncludeCaddyfile` 开关透传）
5. 调 `scripts\status.ps1` 打印快照

也可在 server 上手工跑：

```powershell
cd C:\Deploy\cloud\cloud\windows
.\scripts\apply-release.ps1 -ZipPath C:\Temp\mia-release\mia-relay-windows-abc1234.zip
```

### SSH 登录准备

一次性在 server 上启用 OpenSSH Server（管理员 PowerShell）：

```powershell
# 安装 & 启动 OpenSSH Server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' `
  -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

本机把公钥放到 server：

```powershell
# server 端（以 Administrator 登录）：
#   $keys = 'C:\ProgramData\ssh\administrators_authorized_keys'
#   把本机 ~/.ssh/id_ed25519.pub 内容追加到 $keys
#   并把该文件 ACL 收到 SYSTEM + Administrators 可读（下面一行完成）：
icacls 'C:\ProgramData\ssh\administrators_authorized_keys' /inheritance:r /grant 'SYSTEM:F' /grant 'BUILTIN\Administrators:F'
Restart-Service sshd
```

---

## 升级（手工路径 / 离线环境）

在本机 Win11 重新走构建三步，得到新 zip；拷到目标机解压覆盖（或解到新目录），然后：

```powershell
.\scripts\upgrade.ps1             # 只换 mia-relay.exe（常用）
.\scripts\upgrade.ps1 -IncludeCaddy         # 顺便换 caddy.exe
.\scripts\upgrade.ps1 -IncludeCaddyfile     # 顺便刷 Caddyfile.windows
```

升级**不触碰** `C:\ProgramData\Mia\`，所以 ACME 证书、`.env`、日志都保留，也不会重签证书。失败时可手工回滚：`Move-Item -Force 'C:\Program Files\Mia\mia-relay.exe.bak' 'C:\Program Files\Mia\mia-relay.exe'`。

---

## 卸载

```powershell
.\scripts\uninstall.ps1          # 默认：保留 ProgramData\Mia（证书 + .env + 日志）
.\scripts\uninstall.ps1 -Purge   # 追加：彻底删 ProgramData\Mia
```

---

## token 轮换

1. 编辑 `C:\ProgramData\Mia\config\.env`，在 `MIA_AUTH_TOKENS` 末尾追加新 token（逗号分隔，过渡期双活）。
2. `Restart-Service MiaRelay`（无需重装服务、不影响 Caddy）。
3. 新 token 同步到 PC Agent / 手机客户端完成切换后，再次编辑 `.env` 删掉旧 token，再 `Restart-Service MiaRelay`。

---

## 常见故障排查

### Q: `install.ps1` 停在"Ports already in use"

`Get-NetTCPConnection -LocalPort 80 -State Listen` 看占用进程。常见元凶：

- **IIS (W3SVC)**：`Stop-Service W3SVC; Set-Service W3SVC -StartupType Disabled`。
- **World Wide Web Publishing Service / BranchCache**：同上处理。
- **Skype / Teams （旧版）**：升级或关闭。
- **http.sys 保留**：`netsh http show urlacl` 查保留项，`netsh http delete urlacl url=http://+:80/` 清除。

### Q: ACME 一直不成功，`https://<MIA_DOMAIN>/health` 返回 502 / 证书错误

用 `status.ps1` 看 caddy 日志里高亮的 ACME 行。最常见：

- DNS 没生效——`nslookup <MIA_DOMAIN>` 和本机公网 IP 不符。
- 云厂商安全组没放 80（Let's Encrypt HTTP-01 需要）。
- 上一次错误触发了 Let's Encrypt **速率限制**（同域名每周 5 次 duplicate）。等几小时或换 staging。

### Q: Windows Defender 删了 `mia-relay.exe`

首次启动 PyInstaller onefile 会解压到 `%TEMP%\_MEI*`，有一定概率被启发式引擎误判：

```powershell
Add-MpPreference -ExclusionPath 'C:\Program Files\Mia\mia-relay.exe'
Add-MpPreference -ExclusionPath 'C:\ProgramData\Mia\'
# 企业 EDR 请走内部白名单流程，上报 SHA256（release.ps1 末尾打印）
```

### Q: `MiaRelay` 服务反复 "Starting → Stopped"

最可能是 `.env` 格式错误（带了引号 / BOM / CRLF 混）或 `MIA_AUTH_TOKENS` 没填。看 `C:\ProgramData\Mia\logs\relay\mia-relay.*.log` 最后 50 行。常见致命日志：`MIA_AUTH_TOKENS is required`。

### Q: 升级后 Caddy 开始重新签证书

`upgrade.ps1` 默认**不**动 Caddy 数据。如果你手工删了 `C:\ProgramData\Mia\caddy\`，Caddy 会重新申请，这会受 Let's Encrypt 速率限制。下次想保留证书，别删这个目录。

---

## 相关文档

- 设计与权衡：[openspec/changes/add-windows-relay-deployment/design.md](../../openspec/changes/add-windows-relay-deployment/design.md)
- 规范（SHALL 级需求）：[openspec/changes/add-windows-relay-deployment/specs/relay-deployment-windows/spec.md](../../openspec/changes/add-windows-relay-deployment/specs/relay-deployment-windows/spec.md)
- Linux/Docker 部署路径：[cloud/README.md](../README.md)
