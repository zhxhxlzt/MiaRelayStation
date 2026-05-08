#Requires -Version 5.1
<#
.SYNOPSIS
  In-place upgrade of Mia Cloud Relay (and optionally Caddy) binaries.

.DESCRIPTION
  Expects to be run from a newer release tree in the same layout as install.ps1.
  Services MUST already be installed (via install.ps1) — this script only swaps
  binaries and restarts, it does NOT re-register services or touch firewall
  rules, ACLs, or .env.

  Caddy's cert data under C:\ProgramData\Mia\caddy\ is NEVER touched: ACME is
  not triggered again.

  Steps:
    1. Require elevation + pre-existing services.
    2. Stop MiaCaddy (reverse proxy first so no new connections arrive).
    3. Stop MiaRelay.
    4. Back up current mia-relay.exe (and caddy.exe if being upgraded) as .bak.
    5. Copy new exes into place.
    6. Start MiaRelay, then MiaCaddy.
    7. Poll /health on loopback.

.PARAMETER IncludeCaddy
  Also upgrade caddy.exe. Default is relay-only (most common case).

.PARAMETER IncludeCaddyfile
  Also refresh the Caddyfile.windows config. Off by default because it would
  restart Caddy with potentially-changed routing; opt in explicitly.
#>
[CmdletBinding()]
param(
    [switch]$IncludeCaddy,
    [switch]$IncludeCaddyfile
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Host "==> Mia Cloud Relay · Windows upgrade" -ForegroundColor Cyan
Assert-Administrator

# ---- Locate new binaries ----------------------------------------------------
$srcRoot = Split-Path -Parent $PSScriptRoot

function Resolve-SourceFile {
    param([string[]]$CandidateRelativePaths, [switch]$Optional)
    foreach ($p in $CandidateRelativePaths) {
        $abs = Join-Path $srcRoot $p
        if (Test-Path -LiteralPath $abs) { return $abs }
    }
    if ($Optional) { return $null }
    throw "Cannot locate any of: $($CandidateRelativePaths -join ', ') under $srcRoot"
}

$newRelayExe  = Resolve-SourceFile @('dist\mia-relay.exe','mia-relay.exe')
$newCaddyExe  = if ($IncludeCaddy)     { Resolve-SourceFile @('dist\caddy.exe','caddy.exe') } else { $null }
$newCaddyfile = if ($IncludeCaddyfile) { Resolve-SourceFile @('config\Caddyfile.windows','Caddyfile.windows') } else { $null }

# ---- Sanity: services exist ------------------------------------------------
foreach ($svc in @($script:MiaRelayService, $script:MiaCaddyService)) {
    if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) {
        throw "Service '$svc' is not installed. Run install.ps1 first."
    }
}

# ---- Stop ------------------------------------------------------------------
Write-Host "==> Stopping services (caddy first, then relay)" -ForegroundColor Cyan
Stop-Service -Name $script:MiaCaddyService -ErrorAction SilentlyContinue
Stop-Service -Name $script:MiaRelayService -ErrorAction SilentlyContinue

# ---- Back up + replace -----------------------------------------------------
function Backup-And-Replace {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$Dst
    )
    if (Test-Path -LiteralPath $Dst) {
        $bak = "$Dst.bak"
        if (Test-Path -LiteralPath $bak) { Remove-Item -Force -LiteralPath $bak }
        Move-Item -Force -LiteralPath $Dst -Destination $bak
        Write-Host "    backed up  : $Dst -> $bak"
    }
    Copy-Item -Force -LiteralPath $Src -Destination $Dst
    Write-Host "    replaced   : $Dst" -ForegroundColor Green
}

Write-Host "==> Swapping binaries" -ForegroundColor Cyan
Backup-And-Replace -Src $newRelayExe -Dst (Join-Path $script:MiaInstallRoot 'mia-relay.exe')
if ($IncludeCaddy) {
    Backup-And-Replace -Src $newCaddyExe -Dst (Join-Path $script:MiaInstallRoot 'caddy.exe')
}
if ($IncludeCaddyfile) {
    Backup-And-Replace -Src $newCaddyfile -Dst (Join-Path $script:MiaInstallRoot 'Caddyfile.windows')
}

# ---- Start -----------------------------------------------------------------
Write-Host "==> Starting services (relay first, then caddy)" -ForegroundColor Cyan
Start-Service -Name $script:MiaRelayService
Start-Service -Name $script:MiaCaddyService

# ---- Health check ----------------------------------------------------------
Write-Host "==> Waiting for relay /health" -ForegroundColor Cyan
try {
    Wait-HealthReady -Url 'http://127.0.0.1:8000/health' -TimeoutSeconds 30
    Write-Host "    relay OK (127.0.0.1:8000/health => 200)" -ForegroundColor Green
} catch {
    Write-Host "    relay did NOT come up after upgrade." -ForegroundColor Red
    Write-Host "    To roll back: Stop-Service MiaRelay; Move-Item -Force 'C:\Program Files\Mia\mia-relay.exe.bak' 'C:\Program Files\Mia\mia-relay.exe'; Start-Service MiaRelay"
    throw
}

Write-Host ""
Write-Host "==> Upgrade complete." -ForegroundColor Green
Write-Host "Caddy cert data at $script:MiaCaddyDataDir was not touched; no ACME re-issuance."
