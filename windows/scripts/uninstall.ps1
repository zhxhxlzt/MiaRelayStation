#Requires -Version 5.1
<#
.SYNOPSIS
  Uninstall Mia Cloud Relay from this Windows Server.

.DESCRIPTION
  Default:  Stop services, uninstall them, delete C:\Program Files\Mia\,
            remove Mia-* firewall rules. C:\ProgramData\Mia\ is PRESERVED
            (certificates, .env, logs all kept for future re-install).

  -Purge :  Additionally delete C:\ProgramData\Mia\ entirely.
#>
[CmdletBinding()]
param(
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Host "==> Mia Cloud Relay · Windows uninstall" -ForegroundColor Cyan
Assert-Administrator

# ---- Stop services ---------------------------------------------------------
foreach ($svc in @($script:MiaCaddyService, $script:MiaRelayService)) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        Write-Host "==> Stopping $svc" -ForegroundColor Cyan
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }
}

# ---- Uninstall services via WinSW wrappers ---------------------------------
$servicesDir = Join-Path $script:MiaInstallRoot 'services'
foreach ($name in @('mia-relay','mia-caddy')) {
    $wrapper = Join-Path $servicesDir "$name.exe"
    if (Test-Path -LiteralPath $wrapper) {
        Write-Host "==> Uninstalling service $name" -ForegroundColor Cyan
        & $wrapper uninstall | Out-Host
        # WinSW returns non-zero if the service was not installed; tolerate.
    } else {
        # Fallback: try sc.exe delete by service id if wrapper is already gone.
        $svcId = if ($name -eq 'mia-relay') { $script:MiaRelayService } else { $script:MiaCaddyService }
        if (Get-Service -Name $svcId -ErrorAction SilentlyContinue) {
            Write-Host "==> Fallback sc.exe delete $svcId" -ForegroundColor Yellow
            & sc.exe delete $svcId | Out-Host
        }
    }
}

# ---- Remove install root ---------------------------------------------------
if (Test-Path -LiteralPath $script:MiaInstallRoot) {
    Write-Host "==> Removing $script:MiaInstallRoot" -ForegroundColor Cyan
    Remove-Item -Recurse -Force -LiteralPath $script:MiaInstallRoot
}

# ---- Firewall rules --------------------------------------------------------
Write-Host "==> Removing Mia-* firewall rules" -ForegroundColor Cyan
Remove-MiaFirewallRules

# ---- Optional: purge ProgramData -------------------------------------------
if ($Purge) {
    if (Test-Path -LiteralPath $script:MiaDataRoot) {
        Write-Host "==> -Purge: removing $script:MiaDataRoot (certs, logs, .env)" -ForegroundColor Yellow
        Remove-Item -Recurse -Force -LiteralPath $script:MiaDataRoot
    }
} else {
    Write-Host ""
    Write-Host "NOTE: $script:MiaDataRoot PRESERVED." -ForegroundColor Green
    Write-Host "      Contains .env, ACME certificates, and logs. Re-install will reuse them."
    Write-Host "      Pass -Purge to fully wipe."
}

Write-Host ""
Write-Host "==> Uninstall complete." -ForegroundColor Green
