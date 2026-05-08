#Requires -Version 5.1
<#
.SYNOPSIS
  Server-side "build from source + upgrade" pipeline for Mia Cloud Relay.

.DESCRIPTION
  This is the source-based counterpart to apply-release.ps1. Instead of
  receiving a pre-built zip over scp, this script:

    1. `git pull --ff-only` in the cloned repo on the server.
    2. Runs cloud\windows\build\build-relay.ps1 in-place to produce a fresh
       cloud\windows\dist\mia-relay.exe from source.
    3. Ensures caddy.exe / winsw.exe are present in dist\ (they are fetched
       once by bootstrap-server.ps1 and thereafter never change).
    4. Calls scripts\upgrade.ps1 to stop services, swap binaries, restart,
       and health-check.
    5. Calls scripts\status.ps1 for a final snapshot.

  Upside vs. zip-ship path:
    * No ~20 MB zip leaves the developer's machine.
    * Developers don't need a local Python build environment.
    * The exe is always built from the exact commit git just pulled.

  Requires on the server (one-time, handled by bootstrap-server.ps1):
    * Python 3.11+ on PATH (3.11 or 3.12 both OK).
    * git on PATH.
    * Outbound HTTPS to PyPI (for the first build; subsequent builds are
      cached in cloud\windows\.build-venv).
    * Admin privileges for the upgrade step.

.PARAMETER RepoRoot
  Path to the cloned repo root (directory containing the `cloud\` subfolder).
  Default: C:\Deploy\cloud

.PARAMETER SkipGitPull
  Do not `git pull`. Useful when the repo was updated out-of-band or the
  working tree has local tweaks you want to keep.

.PARAMETER Clean
  Forwarded to build-relay.ps1 — wipe the build venv and rebuild from scratch.
  Use this if dependencies drift or PyInstaller misbehaves.

.PARAMETER IncludeCaddy
  Forwarded to upgrade.ps1 — also swap caddy.exe. (caddy.exe is NOT rebuilt;
  upgrade.ps1 picks it up from dist\ as-is.)

.PARAMETER IncludeCaddyfile
  Forwarded to upgrade.ps1 — also refresh Caddyfile.windows.

.EXAMPLE
  # Typical: pull latest, rebuild exe, swap relay only.
  .\build-on-server.ps1

.EXAMPLE
  # Repo already pulled; just rebuild + swap.
  .\build-on-server.ps1 -SkipGitPull

.EXAMPLE
  # Full clean rebuild; also refresh Caddyfile.
  .\build-on-server.ps1 -Clean -IncludeCaddyfile
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = 'C:\Deploy\cloud',
    [switch]$SkipGitPull,
    [switch]$Clean,
    [switch]$IncludeCaddy,
    [switch]$IncludeCaddyfile
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }

Write-Host "==> Mia Cloud Relay · build-on-server (source → exe → upgrade)" -ForegroundColor Cyan
Assert-Administrator

# ---- Resolve paths ---------------------------------------------------------
# This script is shipped inside the repo at cloud\windows\scripts\; when
# invoked from the repo directly, $PSScriptRoot already points there and
# $RepoRoot is its great-grandparent. When invoked from an extracted zip
# (unusual for this source path, but allowed), $RepoRoot must be passed
# explicitly or default to C:\Deploy\cloud.

if (-not (Test-Path -LiteralPath $RepoRoot)) {
    throw "RepoRoot not found: $RepoRoot. Clone the repo first, or pass -RepoRoot."
}

$windowsDir    = Join-Path $RepoRoot 'cloud\windows'
$buildScript   = Join-Path $windowsDir 'build\build-relay.ps1'
$upgradeScript = Join-Path $windowsDir 'scripts\upgrade.ps1'
$statusScript  = Join-Path $windowsDir 'scripts\status.ps1'
$distDir       = Join-Path $windowsDir 'dist'

foreach ($p in @($buildScript, $upgradeScript, $statusScript)) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Required script missing: $p. Is $RepoRoot really the repo root?"
    }
}
Write-Ok "repo   : $RepoRoot"

# ---- Step 1: git pull ------------------------------------------------------
if (-not $SkipGitPull) {
    Write-Step "git pull --ff-only in $RepoRoot"
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        throw "git not on PATH. Install Git for Windows, or pass -SkipGitPull."
    }
    # Reject if working tree is dirty — refuse to clobber local edits.
    $dirty = & git -C $RepoRoot status --porcelain
    if (-not [string]::IsNullOrWhiteSpace($dirty)) {
        Write-Warn2 "working tree has local changes; skipping pull to avoid conflicts:"
        $dirty | ForEach-Object { Write-Warn2 "  $_" }
    } else {
        & git -C $RepoRoot pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            throw "git pull --ff-only failed. Resolve manually, then re-run with -SkipGitPull."
        }
        $head = (& git -C $RepoRoot rev-parse --short HEAD).Trim()
        Write-Ok "pulled; HEAD=$head"
    }
} else {
    Write-Step "git pull skipped (-SkipGitPull)"
}

# ---- Step 2: build-relay.ps1 (produces dist\mia-relay.exe) -----------------
Write-Step "build-relay.ps1 (source → mia-relay.exe)"

# Python presence is validated by build-relay.ps1 itself; just surface the
# version up front for easier triage if it fails.
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    throw "python not on PATH. Install Python 3.11+ (see bootstrap-server.ps1), then retry."
}
Write-Ok ("python : {0}" -f ((& python --version 2>&1) -replace '\s+', ' '))

$buildArgs = @{}
if ($Clean) { $buildArgs['Clean'] = $true }
& $buildScript @buildArgs
if ($LASTEXITCODE -ne 0) { throw "build-relay.ps1 failed." }

$newRelayExe = Join-Path $distDir 'mia-relay.exe'
if (-not (Test-Path -LiteralPath $newRelayExe)) {
    throw "build-relay.ps1 succeeded but $newRelayExe is missing."
}
Write-Ok ("built  : {0} ({1:N2} MB)" -f $newRelayExe, ((Get-Item $newRelayExe).Length / 1MB))

# ---- Step 3: sanity-check caddy.exe / winsw.exe in dist --------------------
# upgrade.ps1 -IncludeCaddy will look for dist\caddy.exe; it's fetched once
# by bootstrap-server.ps1 and thereafter cached. winsw.exe is not touched at
# upgrade time, only at install time, so we don't require it here.
if ($IncludeCaddy) {
    $caddyExe = Join-Path $distDir 'caddy.exe'
    if (-not (Test-Path -LiteralPath $caddyExe)) {
        throw "IncludeCaddy requested but $caddyExe is missing. Run bootstrap-server.ps1 -RefreshCaddy, or drop caddy.exe into $distDir manually."
    }
}

# ---- Step 4: upgrade.ps1 ---------------------------------------------------
Write-Step "upgrade.ps1 (stop → swap → restart → /health)"
$upgradeArgs = @{}
if ($IncludeCaddy)     { $upgradeArgs['IncludeCaddy']     = $true }
if ($IncludeCaddyfile) { $upgradeArgs['IncludeCaddyfile'] = $true }
& $upgradeScript @upgradeArgs
if ($LASTEXITCODE -ne 0) {
    throw "upgrade.ps1 failed. Inspect $script:MiaLogsRelayDir for details; .bak files are still in place for manual rollback."
}

# ---- Step 5: status.ps1 (best-effort) --------------------------------------
Write-Step "status.ps1"
try {
    & $statusScript
} catch {
    Write-Warn2 "status.ps1 threw: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "==> build-on-server complete." -ForegroundColor Green
Write-Host "    Source : $RepoRoot (HEAD as of this run)"
Write-Host "    Output : $newRelayExe"
Write-Host "    Verify : curl https://<MIA_DOMAIN>/health"
