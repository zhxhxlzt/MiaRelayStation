#Requires -Version 5.1
<#
.SYNOPSIS
  Install Mia Cloud Relay as two Windows Services (MiaRelay + MiaCaddy).

.DESCRIPTION
  Idempotent installer. Run from an elevated PowerShell in the directory
  produced by release.ps1 (or, for local dev, cloud/windows/).

  Expected layout relative to this script:
    ..\service\mia-relay.xml
    ..\service\mia-caddy.xml
    ..\service\mia-relay-launcher.cmd
    ..\service\mia-caddy-launcher.cmd
    ..\config\Caddyfile.windows
    ..\config\env.example
    ..\dist\mia-relay.exe
    ..\dist\caddy.exe
    ..\dist\winsw.exe

  When packaged by release.ps1 the layout is flattened (no dist/ or service/
  nesting); this script accepts either.

.NOTES
  Re-runs are safe: existing services are left running; binaries / configs
  are overwritten; .env is preserved.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Dot-source shared helpers.
. (Join-Path $PSScriptRoot 'common.ps1')

# ---- Step 1: pre-flight -----------------------------------------------------

Write-Host "==> Mia Cloud Relay · Windows installer" -ForegroundColor Cyan
Assert-Administrator
Assert-DotNetFramework48

# ---- Step 2: resolve source layout -----------------------------------------
# Support both "dev tree" (cloud/windows/) and "release zip" (flattened).
$srcRoot = Split-Path -Parent $PSScriptRoot  # default: cloud/windows/
function Resolve-SourceFile {
    param([Parameter(Mandatory)][string[]]$CandidateRelativePaths)
    foreach ($p in $CandidateRelativePaths) {
        $abs = Join-Path $srcRoot $p
        if (Test-Path -LiteralPath $abs) { return $abs }
    }
    $joined = ($CandidateRelativePaths -join ', ')
    throw "Cannot locate any of: $joined (under $srcRoot)"
}

$srcRelayXml        = Resolve-SourceFile @('service\mia-relay.xml','mia-relay.xml')
$srcCaddyXml        = Resolve-SourceFile @('service\mia-caddy.xml','mia-caddy.xml')
$srcRelayLauncher   = Resolve-SourceFile @('service\mia-relay-launcher.cmd','mia-relay-launcher.cmd')
$srcCaddyLauncher   = Resolve-SourceFile @('service\mia-caddy-launcher.cmd','mia-caddy-launcher.cmd')
$srcCaddyfile       = Resolve-SourceFile @('config\Caddyfile.windows','Caddyfile.windows')
$srcEnvExample      = Resolve-SourceFile @('config\env.example','env.example')
$srcRelayExe        = Resolve-SourceFile @('dist\mia-relay.exe','mia-relay.exe')
$srcCaddyExe        = Resolve-SourceFile @('dist\caddy.exe','caddy.exe')
$srcWinswExe        = Resolve-SourceFile @('dist\winsw.exe','winsw.exe')

# ---- Step 3: check 80/443 are free -----------------------------------------
Write-Host "==> Checking ports 80/443 are free" -ForegroundColor Cyan
$occupants = Get-PortOccupants -Ports 80,443
if ($occupants.Count -gt 0) {
    Write-Host "Ports already in use:" -ForegroundColor Red
    $occupants | Format-Table -AutoSize | Out-Host
    throw "Stop the occupying process(es), or disable the occupying service (e.g. 'Stop-Service W3SVC'), then re-run install.ps1."
}

# ---- Step 4: create directory tree -----------------------------------------
Write-Host "==> Creating directories" -ForegroundColor Cyan
Ensure-Directory $script:MiaInstallRoot
Ensure-Directory $script:MiaInstallBinDir
Ensure-Directory $script:MiaDataRoot
Ensure-Directory $script:MiaConfigDir
Ensure-Directory $script:MiaCaddyDataDir
Ensure-Directory $script:MiaLogsRelayDir
Ensure-Directory $script:MiaLogsCaddyDir

# ---- Step 5: lock down config ACL ------------------------------------------
Write-Host "==> Tightening ACL on $script:MiaConfigDir" -ForegroundColor Cyan
Set-SecureConfigAcl -Path $script:MiaConfigDir

# ---- Step 6: copy binaries --------------------------------------------------
Write-Host "==> Copying binaries to $script:MiaInstallRoot" -ForegroundColor Cyan
Copy-Item -Force -LiteralPath $srcRelayExe   -Destination (Join-Path $script:MiaInstallRoot 'mia-relay.exe')
Copy-Item -Force -LiteralPath $srcCaddyExe   -Destination (Join-Path $script:MiaInstallRoot 'caddy.exe')
Copy-Item -Force -LiteralPath $srcWinswExe   -Destination (Join-Path $script:MiaInstallRoot 'winsw.exe')
Copy-Item -Force -LiteralPath $srcCaddyfile  -Destination (Join-Path $script:MiaInstallRoot 'Caddyfile.windows')

# ---- Step 7: install WinSW xml + launchers ---------------------------------
# WinSW convention: the xml sits next to winsw.exe renamed to match the exe
# base name. We keep one winsw.exe and use two *per-service* copies to
# simplify the xml lookup:
#   C:\Program Files\Mia\services\mia-relay.exe  (copy of winsw.exe)
#   C:\Program Files\Mia\services\mia-relay.xml
#   C:\Program Files\Mia\services\mia-caddy.exe  (copy of winsw.exe)
#   C:\Program Files\Mia\services\mia-caddy.xml
$servicesDir = Join-Path $script:MiaInstallRoot 'services'
Ensure-Directory $servicesDir
$relayWrapper = Join-Path $servicesDir 'mia-relay.exe'
$caddyWrapper = Join-Path $servicesDir 'mia-caddy.exe'
Copy-Item -Force -LiteralPath (Join-Path $script:MiaInstallRoot 'winsw.exe') -Destination $relayWrapper
Copy-Item -Force -LiteralPath (Join-Path $script:MiaInstallRoot 'winsw.exe') -Destination $caddyWrapper
Copy-Item -Force -LiteralPath $srcRelayXml -Destination (Join-Path $servicesDir 'mia-relay.xml')
Copy-Item -Force -LiteralPath $srcCaddyXml -Destination (Join-Path $servicesDir 'mia-caddy.xml')

# Launchers live in bin/ because the xml references %BASE%\bin\*-launcher.cmd,
# and %BASE% at runtime is the dir of the wrapper exe (= servicesDir). We need
# a bin/ under servicesDir (not under MiaInstallRoot!) to satisfy %BASE%\bin.
$servicesBinDir = Join-Path $servicesDir 'bin'
Ensure-Directory $servicesBinDir
Copy-Item -Force -LiteralPath $srcRelayLauncher -Destination (Join-Path $servicesBinDir 'mia-relay-launcher.cmd')
Copy-Item -Force -LiteralPath $srcCaddyLauncher -Destination (Join-Path $servicesBinDir 'mia-caddy-launcher.cmd')

# ---- Step 8: ensure .env exists --------------------------------------------
if (-not (Test-Path -LiteralPath $script:MiaEnvFile)) {
    Write-Host "==> First-time install: seeding .env from env.example" -ForegroundColor Yellow
    Copy-Item -Force -LiteralPath $srcEnvExample -Destination $script:MiaEnvFile
    Write-Host "    EDIT $script:MiaEnvFile with real MIA_AUTH_TOKENS and MIA_DOMAIN before the services will start healthy." -ForegroundColor Yellow
    Write-Host "    Opening in notepad now..." -ForegroundColor Yellow
    Start-Process -FilePath notepad.exe -ArgumentList $script:MiaEnvFile -Wait
} else {
    Write-Host "==> Existing .env preserved at $script:MiaEnvFile" -ForegroundColor Green
}

# ---- Step 9: firewall -------------------------------------------------------
Write-Host "==> Configuring firewall rules" -ForegroundColor Cyan
Set-MiaFirewallRules

# ---- Step 10: install & start services -------------------------------------
Write-Host "==> Installing services via WinSW" -ForegroundColor Cyan

# Helper: ensure service is installed (uninstall first if already registered).
function Install-WinswService {
    param([string]$WrapperExe, [string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "    Service $ServiceName already registered; re-installing..." -ForegroundColor Yellow
        Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
        & $WrapperExe uninstall | Out-Host
    }
    & $WrapperExe install | Out-Host
}

Install-WinswService -WrapperExe $relayWrapper -ServiceName $script:MiaRelayService
Install-WinswService -WrapperExe $caddyWrapper -ServiceName $script:MiaCaddyService

Write-Host "==> Starting services" -ForegroundColor Cyan
Start-Service -Name $script:MiaRelayService
Start-Service -Name $script:MiaCaddyService

# ---- Step 11: health check -------------------------------------------------
Write-Host "==> Waiting for relay /health" -ForegroundColor Cyan
try {
    Wait-HealthReady -Url 'http://127.0.0.1:8000/health' -TimeoutSeconds 30
    Write-Host "    relay OK (127.0.0.1:8000/health => 200)" -ForegroundColor Green
} catch {
    Write-Host "    relay did NOT come up in 30s." -ForegroundColor Red
    Write-Host "    Most recent relay log lines:" -ForegroundColor Yellow
    $latestLog = Get-ChildItem -LiteralPath $script:MiaLogsRelayDir -Filter 'mia-relay.*.log' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestLog) { Get-Content -Tail 50 -LiteralPath $latestLog.FullName | Out-Host }
    throw
}

# ---- Step 12: final guidance -----------------------------------------------
Write-Host ""
Write-Host "==> Install complete." -ForegroundColor Green
Write-Host "Next:"
Write-Host "  1. Ensure DNS A record for MIA_DOMAIN points at this server's public IP."
Write-Host "  2. Open https://<MIA_DOMAIN>/health from another host; expect {`"ok`":true}."
Write-Host "     (First visit may take 30-60s while Caddy issues the Let's Encrypt cert.)"
Write-Host "  3. Run scripts\status.ps1 for a summary anytime."
