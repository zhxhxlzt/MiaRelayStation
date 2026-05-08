# Mia Cloud Relay · Server 端 AI 交接文档

> **读者：运行在 Windows Server 上的 AI 编码助手（CodeBuddy 等）。**
> **任务：把 Mia Cloud Relay 在本机跑通——两个 Windows 服务 `MiaRelay` + `MiaCaddy` 处于 `Running` 状态，`/health` 返回 200。**

---

## 1. 你要做什么（一句话）

在当前 Windows Server 上，**让 `MiaRelay` 和 `MiaCaddy` 两个服务跑起来，并通过 `/health` 健康检查**。前置的构建、脚本、配置都已经做好了，你要解决的是**部署执行过程中遇到的问题**。

### 成功判据（你自己用这个判定"完成"）

以管理员 PowerShell 运行，四项全部为真才算完成：

```powershell
# 1. 两个服务都在 Running
(Get-Service MiaRelay).Status -eq 'Running'
(Get-Service MiaCaddy).Status -eq 'Running'

# 2. relay 本地健康
(Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/health).StatusCode -eq 200

# 3. caddy 监听 443
(Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue) -ne $null

# 4. 外部可访问（可选，需要 DNS / 端口放行）
# 在另一台机器上 curl https://<MIA_DOMAIN>/health 期望 200 + {"ok":true}
```

---

## 2. 背景：这套东西的架构

这是一个 **Python FastAPI WebSocket 中继**，用 PyInstaller 打包成单 exe，由 WinSW 封装成 Windows 服务，前面挂 Caddy 做 HTTPS 反代 + Let's Encrypt 自动证书。**所有代码和脚本已经就绪**，你不需要改任何业务代码。

### 关键组件职责

| 组件 | 路径 | 职责 |
|---|---|---|
| `mia-relay.exe` | `C:\Program Files\Mia\mia-relay.exe` | Python FastAPI/uvicorn，监听 `127.0.0.1:8000` |
| `caddy.exe` | `C:\Program Files\Mia\caddy.exe` | 反代 `:443 → 127.0.0.1:8000`，自动申请 Let's Encrypt 证书 |
| `winsw.exe`（两个副本） | `C:\Program Files\Mia\services\mia-relay.exe`<br>`C:\Program Files\Mia\services\mia-caddy.exe` | Windows 服务壳（WinSW v3 约定：`<name>.exe` 旁边必须有同名 `<name>.xml`） |
| `.env` | `C:\ProgramData\Mia\config\.env` | 含 `MIA_AUTH_TOKENS` 和 `MIA_DOMAIN`，ACL 限 SYSTEM+Administrators |
| `Caddyfile.windows` | `C:\Program Files\Mia\Caddyfile.windows` | Caddy 路由规则，读取 `{$MIA_DOMAIN}` |
| Launcher | `C:\Program Files\Mia\services\bin\mia-relay-launcher.cmd`<br>`C:\Program Files\Mia\services\bin\mia-caddy-launcher.cmd` | WinSW 调用的 `.cmd`，负责加载 `.env` 并 exec 真 exe |

### 关键设计：WinSW v3 的 "per-service 副本"模式

WinSW v3 **不接受命令行传 xml 路径**。它的硬性约定是：

- 服务可执行壳名为 `<whatever>.exe`
- **同目录、同名**的 `<whatever>.xml` 必须存在
- 服务 id 取自 xml 里的 `<id>` 标签

所以 `install.ps1` 的做法是把 `winsw.exe` 复制两份：

```
C:\Program Files\Mia\services\
├── mia-relay.exe     ← winsw.exe 的副本（WinSW 服务壳，不是 Python relay！）
├── mia-relay.xml     ← <id>MiaRelay</id>
├── mia-caddy.exe     ← winsw.exe 的另一份副本
├── mia-caddy.xml     ← <id>MiaCaddy</id>
└── bin\
    ├── mia-relay-launcher.cmd
    └── mia-caddy-launcher.cmd
```

**永远不要直接运行 `"C:\Program Files\Mia\winsw.exe" install`——那会在 Program Files\Mia 找 `winsw.xml`，找不到就报 `Unable to locate winsw.[xml|yml]`。**

正确的调用方式是用副本：
```powershell
& "C:\Program Files\Mia\services\mia-relay.exe" install
& "C:\Program Files\Mia\services\mia-caddy.exe" install
```

---

## 3. 现场排查（你第一步就做这个）

以**管理员 PowerShell** 运行下面这段诊断脚本，把输出留着对照后面的决策树：

```powershell
Write-Host "=== 1. 服务状态 ===" -ForegroundColor Cyan
Get-Service MiaRelay, MiaCaddy -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType

Write-Host "`n=== 2. 根目录（真正的 exe） ===" -ForegroundColor Cyan
Get-ChildItem "C:\Program Files\Mia\" -ErrorAction SilentlyContinue -File | Format-Table Name, Length

Write-Host "`n=== 3. services 目录（WinSW 副本 + xml） ===" -ForegroundColor Cyan
Get-ChildItem "C:\Program Files\Mia\services\" -ErrorAction SilentlyContinue | Format-Table Name, Length

Write-Host "`n=== 4. services\bin 目录（launcher） ===" -ForegroundColor Cyan
Get-ChildItem "C:\Program Files\Mia\services\bin\" -ErrorAction SilentlyContinue | Format-Table Name, Length

Write-Host "`n=== 5. .env ===" -ForegroundColor Cyan
if (Test-Path "C:\ProgramData\Mia\config\.env") {
    Get-Content "C:\ProgramData\Mia\config\.env" | ForEach-Object {
        if ($_ -match '^MIA_AUTH_TOKENS=(.+)') { "MIA_AUTH_TOKENS=***(len=$($matches[1].Length))***" }
        elseif ($_ -match '^MIA_DOMAIN=(.+)')  { "MIA_DOMAIN=$($matches[1])" }
        else { $_ }
    }
} else {
    Write-Host "❌ .env 不存在" -ForegroundColor Red
}

Write-Host "`n=== 6. 80/443/8000 端口占用 ===" -ForegroundColor Cyan
foreach ($port in 80,443,8000) {
    $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($conns) {
        foreach ($c in $conns) {
            $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            "  Port $port: PID=$($c.OwningProcess) Name=$($p.ProcessName)"
        }
    } else {
        "  Port $port: free"
    }
}

Write-Host "`n=== 7. 健康探测 ===" -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/health -TimeoutSec 3
    "  /health => $($r.StatusCode) $($r.Content)"
} catch {
    "  /health => FAIL: $($_.Exception.Message)"
}

Write-Host "`n=== 8. relay 日志（最后 40 行） ===" -ForegroundColor Cyan
$log = Get-ChildItem "C:\ProgramData\Mia\logs\relay\" -Filter "*.log" -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) { "文件: $($log.FullName)"; Get-Content -Tail 40 $log.FullName } else { "（无日志）" }

Write-Host "`n=== 9. caddy 日志（最后 40 行） ===" -ForegroundColor Cyan
$log = Get-ChildItem "C:\ProgramData\Mia\logs\caddy\" -Filter "*.log" -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) { "文件: $($log.FullName)"; Get-Content -Tail 40 $log.FullName } else { "（无日志）" }

Write-Host "`n=== 10. 最近的安装包位置 ===" -ForegroundColor Cyan
Get-ChildItem "C:\" -Filter "mia-relay-windows-*" -Recurse -ErrorAction SilentlyContinue -Depth 3 |
    Select-Object -First 5 FullName
```

---

## 4. 决策树（根据诊断输出选分支）

### 分支 A：什么都没有——从零装

**征兆**：诊断输出里，第 2、3、4 条都是空的；服务也不存在。

**做法**：用户的 release zip 应该已经解压到某个目录（常见 `C:\MiaRelayStation\windows\` 或 `C:\Temp\mia-relay-windows-<sha>\`）。找到含 `scripts\install.ps1` 的目录，然后：

```powershell
# 1. 保险：右键 zip 选过"解除锁定"？用命令也能做：
Get-ChildItem -Path <解压目录> -Recurse | Unblock-File

# 2. 进解压目录
Set-Location <解压目录>

# 3. 允许本会话执行脚本
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# 4. 一键安装（幂等，可以重跑）
.\scripts\install.ps1
```

`install.ps1` 会：

1. 检查管理员权限、.NET 4.8
2. 检查 80/443 没被占用（**若被占用会直接抛错**，见分支 D）
3. 建目录、copy 二进制、copy xml+launcher 到 services/、初始化 .env（第一次会 **弹记事本让用户填**，保存关闭后脚本继续）
4. 注册两个服务 → 启动 → 探测 `/health`

**预期输出**：看到 "Install complete." 绿字就成。

### 分支 B：文件全在，服务没注册 / 起不来

**征兆**：第 3 条里有 `mia-relay.exe` + `mia-relay.xml` + `mia-caddy.exe` + `mia-caddy.xml`；但第 1 条没服务，或服务是 Stopped。

**做法**：直接跑 install.ps1 重装（它是幂等的）。如果用户坚持不重跑，手动注册：

```powershell
# 先清残留（不报错就忽略）
Stop-Service MiaRelay, MiaCaddy -ErrorAction SilentlyContinue
sc.exe delete MiaRelay 2>&1 | Out-Null
sc.exe delete MiaCaddy 2>&1 | Out-Null

# 用副本注册（关键！不是用 winsw.exe 自己）
& "C:\Program Files\Mia\services\mia-relay.exe" install
& "C:\Program Files\Mia\services\mia-caddy.exe" install

# 启动
Start-Service MiaRelay
Start-Sleep -Seconds 3
Start-Service MiaCaddy

Get-Service MiaRelay, MiaCaddy
```

### 分支 C：服务起了但立刻停——看日志定位真因

**征兆**：`Get-Service MiaRelay` 状态在 Starting ↔ Stopped 之间反复；或 `/health` 超时。

**做法**：读诊断里第 8、9 条的日志尾巴。常见错因与对策：

| 日志关键行 | 根因 | 修法 |
|---|---|---|
| `MIA_AUTH_TOKENS is required` | `.env` 里 token 没填 / 还是 `replace-me-...` | 编辑 `C:\ProgramData\Mia\config\.env`，填真 token（PowerShell 生成：`[Convert]::ToBase64String((1..32 \| %{ [byte](Get-Random -Max 256) }))`），保存后 `Restart-Service MiaRelay` |
| `.env missing at C:\ProgramData\Mia\config\.env` | launcher 找不到 .env | `Copy-Item "C:\Program Files\Mia\env.example" "C:\ProgramData\Mia\config\.env"`（若 env.example 不在这里，从解压包里找） |
| `Address already in use` / `port 8000` | 8000 被别的进程占了 | `Get-NetTCPConnection -LocalPort 8000 -State Listen` 看占用方；必要时换端口（改 `mia-relay.xml` 里的 `MIA_RELAY_PORT` + `Caddyfile.windows` 里的 upstream） |
| `no such host` / DNS / ACME error（Caddy 日志） | `MIA_DOMAIN` 指向的域名 DNS 没生效、或 80/443 对外被安全组挡住 | 见分支 E |
| relay 日志完全是空的，但服务反复停 | launcher 连 exe 都没 exec 到；先手跑 launcher 看输出 | `cmd /c "C:\Program Files\Mia\services\bin\mia-relay-launcher.cmd"`，直接看 console 错误 |

### 分支 D：`Ports already in use` 阻断安装

**征兆**：`install.ps1` 抛 `Stop the occupying process(es)...`。

**做法**：

```powershell
# 看谁占了
foreach ($p in 80,443) {
    Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue |
      ForEach-Object {
          $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
          "Port $p: PID=$($_.OwningProcess) Name=$($proc.ProcessName) Path=$($proc.Path)"
      }
}
```

典型元凶与处理：

- **IIS (W3SVC)**：`Stop-Service W3SVC; Set-Service W3SVC -StartupType Disabled`
- **http.sys URL 保留**：`netsh http show urlacl`，必要时 `netsh http delete urlacl url=http://+:80/`
- **World Wide Web Publishing Service**：同 W3SVC 处理
- 其他：先问用户这是什么服务再决定，**不要未经同意停用户的业务进程**

处理后重跑 `install.ps1`。

### 分支 E：内部 OK 但外部 https 访问不了

**征兆**：`Invoke-WebRequest http://127.0.0.1:8000/health` 返回 200，但从外网 `https://<域名>/health` 失败。

**做法**（按顺序排查）：

1. **DNS**：`Resolve-DnsName <MIA_DOMAIN>` → 看返回的 A 记录是不是本机公网 IP。公网 IP 可以 `(Invoke-RestMethod https://api.ipify.org)` 查。
2. **Windows 防火墙**：`Get-NetFirewallRule -DisplayName 'Mia-*' | ft DisplayName, Enabled, Action`，应有 `Mia-Allow-HTTP` / `Mia-Allow-HTTPS` / `Mia-Block-Relay` 三条。
3. **云厂商安全组/网络 ACL**：这一层脚本碰不到，必须让用户在控制台放行 80、443 入站 TCP。**Let's Encrypt HTTP-01 挑战需要 80 端口可达**，80 被挡就拿不到证书。
4. **Caddy ACME 日志**：查诊断第 9 条，找带 `obtain`、`challenge`、`error` 的行。如果看到速率限制（`too many certificates already issued`），说明短期内请求过多，等几小时或临时用 staging endpoint。

---

## 5. 常用运维命令速查

```powershell
# 重启单个服务
Restart-Service MiaRelay
Restart-Service MiaCaddy

# 跑状态快照（脚本自带）
<解压目录>\scripts\status.ps1

# 刷 xml 改动到 Windows 服务（改了 mia-relay.xml 后必须 refresh）
& "C:\Program Files\Mia\services\mia-relay.exe" refresh

# 卸载服务（保留数据）
& "C:\Program Files\Mia\services\mia-relay.exe" uninstall
& "C:\Program Files\Mia\services\mia-caddy.exe" uninstall

# 彻底卸（含 ProgramData\Mia）
<解压目录>\scripts\uninstall.ps1 -Purge
```

---

## 6. 硬性红线（请严格遵守）

1. **不要改业务代码**（`mia-relay.exe` 背后的 Python 源码、FastAPI 路由等）。本任务只关心部署能不能跑起来。
2. **不要把 token 写死到 xml 或脚本里**。token 只能在 `.env`，且 `.env` 的 ACL 不能放宽。
3. **不要直接 `& "C:\Program Files\Mia\winsw.exe" install <xml>`**——WinSW v3 不支持这种调用，会报 `Unable to locate winsw.[xml|yml]`。永远用 `services\mia-relay.exe` / `services\mia-caddy.exe` 这两个副本。
4. **不要手动删 `C:\ProgramData\Mia\caddy\`**——里面是 ACME 证书，删了会触发重新签发，而 Let's Encrypt **每周每域名 5 次** 的速率限制一旦触发就要等。
5. **遇到"停掉某个非 Mia 的用户业务进程"的诱惑时，先问用户**。比如 IIS、第三方 Web 服务等。
6. **相对路径少用**，脚本和命令里尽量全绝对路径，避免 working dir 错位。

---

## 7. 如果上面都不管用——收集证据上报

把下面这段的完整输出打包交给用户（或回给 D:/Mia 那边的 AI）：

```powershell
$report = "$env:TEMP\mia-diag-$(Get-Date -Format yyyyMMdd-HHmmss).txt"
& {
    "=== System ==="
    Get-ComputerInfo | Select-Object WindowsProductName, OsVersion, CsName
    "`n=== .NET ==="
    (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    "`n=== Services ==="
    Get-Service MiaRelay, MiaCaddy -ErrorAction SilentlyContinue | Format-List *
    "`n=== Files ==="
    Get-ChildItem "C:\Program Files\Mia\" -Recurse -ErrorAction SilentlyContinue | Select-Object FullName, Length
    "`n=== .env (redacted) ==="
    if (Test-Path "C:\ProgramData\Mia\config\.env") {
        Get-Content "C:\ProgramData\Mia\config\.env" | ForEach-Object {
            if ($_ -match '^(MIA_AUTH_TOKENS)=(.+)') { "$($matches[1])=***(len=$($matches[2].Length))***" }
            else { $_ }
        }
    }
    "`n=== Relay log ==="
    Get-ChildItem "C:\ProgramData\Mia\logs\relay\" -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
        ForEach-Object { Get-Content -Tail 100 $_.FullName }
    "`n=== Caddy log ==="
    Get-ChildItem "C:\ProgramData\Mia\logs\caddy\" -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
        ForEach-Object { Get-Content -Tail 100 $_.FullName }
    "`n=== Ports ==="
    foreach ($p in 80,443,8000) {
        "Port $p:"
        Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue |
            Select-Object LocalAddress, LocalPort, OwningProcess
    }
    "`n=== Firewall ==="
    Get-NetFirewallRule -DisplayName 'Mia-*' -ErrorAction SilentlyContinue | Format-Table DisplayName, Enabled, Action, Direction
} *>&1 | Out-File -FilePath $report -Encoding utf8
Write-Host "Report written to: $report" -ForegroundColor Green
notepad $report
```

---

## 8. 标准完成流程（理想路径）

对于一台**完全干净**的 Windows Server，顺一遍一般是这样：

```powershell
# 0. 以管理员打开 PowerShell

# 1. 找到 release 包的解压目录，比如：
Set-Location C:\MiaRelayStation\windows    # 根据实际情况改

# 2. 解除网络下载锁定 + 放开执行策略
Get-ChildItem -Recurse | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# 3. 跑一键安装
.\scripts\install.ps1
# → 首次会弹记事本编辑 .env
# → 填真实 MIA_AUTH_TOKENS（建议用 `[Convert]::ToBase64String((1..32 | %{ [byte](Get-Random -Max 256) }))` 生成）
# → 填真实 MIA_DOMAIN（必须已有 DNS A 记录指向本机公网 IP）
# → 保存、关闭记事本，脚本继续

# 4. 看到 "Install complete." 后验证
.\scripts\status.ps1
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/health

# 5. 从外网另一台机器验证（首次 https 可能等 30-60s 等 Caddy 签证书）
#   curl https://<MIA_DOMAIN>/health
```

**就这样。**遇到任何步骤出错，回到第 3 节跑诊断脚本，然后按第 4 节的决策树走。

---

## 附：用户原始文档

完整的架构、构建、升级、卸载说明见同目录的 [README.md](./README.md)。本文档是**给 AI 的行动手册**，README 是**给人类的背景资料**，两者不冲突。
