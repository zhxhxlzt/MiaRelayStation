#Requires -Version 5.1
<#
.SYNOPSIS
  Print a quick operational snapshot of the Mia Cloud Relay deployment.

.DESCRIPTION
  Read-only. Safe to run at any time, elevated or not (but some fields show
  "Access denied" when unelevated, e.g. firewall rules).

  Sections:
    1. Services (MiaRelay, MiaCaddy) — status + uptime
    2. Listening ports on 80 / 443 / 8000
    3. /health probe (localhost and optionally public)
    4. Firewall rules (Mia-*)
    5. Recent log tails (relay + caddy), with ACME lines highlighted
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'common.ps1')

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
}

# ---- 1. Services -----------------------------------------------------------
Write-Section "Services"
foreach ($name in @($script:MiaRelayService, $script:MiaCaddyService)) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) {
        "{0,-12} {1,-10} StartType={2}" -f $svc.Name, $svc.Status, $svc.StartType |
            Write-Host
    } else {
        Write-Host ("{0,-12} NOT INSTALLED" -f $name) -ForegroundColor Yellow
    }
}

# ---- 2. Listening ports ----------------------------------------------------
Write-Section "Listening ports"
$ports = Get-PortOccupants -Ports 80,443,8000
if ($ports) {
    $ports | Format-Table -AutoSize | Out-Host
} else {
    Write-Host "No listeners on 80/443/8000." -ForegroundColor Yellow
}

# ---- 3. Health probe -------------------------------------------------------
Write-Section "Local /health probe"
try {
    $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:8000/health' -UseBasicParsing -TimeoutSec 3
    Write-Host ("status={0} body={1}" -f $resp.StatusCode, $resp.Content) -ForegroundColor Green
} catch {
    Write-Host ("FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# ---- 4. Firewall rules -----------------------------------------------------
Write-Section "Firewall rules (Mia-*)"
$rules = Get-NetFirewallRule -DisplayName "$($script:MiaFirewallPrefix)*" -ErrorAction SilentlyContinue
if ($rules) {
    $rules | ForEach-Object {
        $port = ($_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort
        "{0,-20} Dir={1,-7} Action={2,-5} Port={3,-6} Enabled={4}" -f `
            $_.DisplayName, $_.Direction, $_.Action, $port, $_.Enabled
    } | Write-Host
} else {
    Write-Host "No Mia-* firewall rules found." -ForegroundColor Yellow
}

# ---- 5. Recent log tails ---------------------------------------------------
function Show-LatestLog {
    param([string]$Dir, [string]$Label, [int]$Lines = 20)
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-Host "$Label : log dir missing ($Dir)" -ForegroundColor Yellow
        return
    }
    $latest = Get-ChildItem -LiteralPath $Dir -Filter '*.log' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        Write-Host "$Label : no .log files yet in $Dir" -ForegroundColor Yellow
        return
    }
    Write-Host ("-- {0}  last {1} lines --" -f $latest.FullName, $Lines) -ForegroundColor DarkCyan
    Get-Content -Tail $Lines -LiteralPath $latest.FullName | ForEach-Object {
        # Highlight ACME / certificate-related lines so operators spot issues.
        if ($_ -match '(?i)acme|certificate|letsencrypt|challenge|ZeroSSL') {
            Write-Host $_ -ForegroundColor Yellow
        } else {
            Write-Host $_
        }
    }
}

Write-Section "Recent relay log"
Show-LatestLog -Dir $script:MiaLogsRelayDir -Label 'relay'

Write-Section "Recent caddy log"
Show-LatestLog -Dir $script:MiaLogsCaddyDir -Label 'caddy'

Write-Host ""
