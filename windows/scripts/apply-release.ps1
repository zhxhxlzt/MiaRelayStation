#Requires -Version 5.1
<#
.SYNOPSIS
  Server-side companion to build\publish-local.ps1.
  Unpack a shipped release zip, refresh the repo, run upgrade.ps1.

.DESCRIPTION
  Run this on the target Windows Server as Administrator. Steps:
    1. Assert admin; sanity-check the zip exists.
    2. git pull --ff-only in the repo so tracked scripts/config are in sync
       with the exe about to be dropped in (skippable with -SkipGitPull).
    3. Extract the zip to a fresh staging dir under $env:TEMP\mia-release\.
    4. Copy the three exes (mia-relay.exe, caddy.exe, winsw.exe) into the
       repo's cloud\windows\dist\ so upgrade.ps1 can find them via its
       usual Resolve-SourceFile fallbacks.
    5. Invoke cloud\windows\scripts\upgrade.ps1 (with forwarded switches).
    6. Run status.ps1 for a quick sanity summary.

  Idempotent: safe to re-run. Preserves .env and Caddy cert data under
  C:\ProgramData\Mia\ (upgrade.ps1 already guarantees that).

.PARAMETER ZipPath
  Path to the release zip on this server. Required. Typically something like
  C:\Temp\mia-release\mia-relay-windows-<sha>.zip.

.PARAMETER RepoRoot
  Path to the cloned git repo root on this server (the directory containing
  the `cloud/` subfolder). Default: C:\Deploy\cloud

.PARAMETER SkipGitPull
  Do not `git pull` in RepoRoot. Useful if the repo is dirty or you've
  manually updated scripts and don't want them overwritten.

.PARAMETER IncludeCaddy
  Forwarded to upgrade.ps1 — also upgrade caddy.exe.

.PARAMETER IncludeCaddyfile
  Forwarded to upgrade.ps1 — also refresh Caddyfile.windows.

.EXAMPLE
  .\apply-release.ps1 -ZipPath C:\Temp\mia-release\mia-relay-windows-abc1234.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ZipPath,
    [string]$RepoRoot = 'C:\Deploy\cloud',
    [switch]$SkipGitPull,
    [switch]$IncludeCaddy,
    [switch]$IncludeCaddyfile
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }

Write-Host "==> Mia Cloud Relay · apply-release (server side)" -ForegroundColor Cyan
Assert-Administrator

# ---- Step 1: validate inputs -----------------------------------------------
if (-not (Test-Path -LiteralPath $ZipPath)) {
    throw "ZipPath not found: $ZipPath"
}
$zipInfo = Get-Item -LiteralPath $ZipPath
Write-Ok ("zip    : {0} ({1:N2} MB)" -f $zipInfo.Name, ($zipInfo.Length / 1MB))

if (-not (Test-Path -LiteralPath $RepoRoot)) {
    throw "RepoRoot not found: $RepoRoot. Clone the repo first, or pass -RepoRoot."
}
$windowsDir = Join-Path $RepoRoot 'cloud\windows'
$upgradeScript = Join-Path $windowsDir 'scripts\upgrade.ps1'
$statusScript  = Join-Path $windowsDir 'scripts\status.ps1'
$distDir       = Join-Path $windowsDir 'dist'
if (-not (Test-Path -LiteralPath $upgradeScript)) {
    throw "upgrade.ps1 not found at $upgradeScript. Is $RepoRoot really the repo root?"
}
Write-Ok "repo   : $RepoRoot"

# ---- Step 2: git pull ------------------------------------------------------
if (-not $SkipGitPull) {
    Write-Step "git pull --ff-only in $RepoRoot"
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        Write-Warn2 "git not on PATH; skipping pull. (Pass -SkipGitPull to silence this.)"
    } else {
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
    }
} else {
    Write-Step "git pull skipped (-SkipGitPull)"
}

# ---- Step 3: extract zip to a fresh staging dir ----------------------------
$stagingRoot = Join-Path $env:TEMP 'mia-release'
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

# Use a per-run subdir keyed to the zip basename so we don't mix files from
# multiple releases.
$stageDir = Join-Path $stagingRoot ([IO.Path]::GetFileNameWithoutExtension($zipInfo.Name))
if (Test-Path -LiteralPath $stageDir) { Remove-Item -Recurse -Force -LiteralPath $stageDir }
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

Write-Step "extract → $stageDir"
# Expand-Archive is fine; files are small, and the built-in saves us a
# 7zip dependency on the server.
Expand-Archive -LiteralPath $ZipPath -DestinationPath $stageDir -Force
Write-Ok ("extracted {0} items" -f (Get-ChildItem -Recurse -LiteralPath $stageDir | Measure-Object).Count)

# ---- Step 4: stage exes into repo's dist/ ----------------------------------
# upgrade.ps1 looks for dist\mia-relay.exe (and optionally dist\caddy.exe,
# config\Caddyfile.windows) under cloud\windows\. By dropping the three
# exes into the repo's dist/ we make upgrade.ps1's happy path work
# uniformly whether triggered from a zip or from a `git pull` of a dev
# that committed a zip separately.
Write-Step "stage new exes into $distDir"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

$toStage = @(
    @{ Name='mia-relay.exe'; Required=$true;  IncludeFlag=$null }
    @{ Name='caddy.exe';     Required=$false; IncludeFlag=$IncludeCaddy.IsPresent }
    @{ Name='winsw.exe';     Required=$false; IncludeFlag=$null }  # winsw never swapped at upgrade time
)
foreach ($item in $toStage) {
    $src = Join-Path $stageDir $item.Name
    if (-not (Test-Path -LiteralPath $src)) {
        if ($item.Required) { throw "release zip is missing required file: $($item.Name)" }
        Write-Warn2 "skipping absent: $($item.Name)"
        continue
    }
    $dst = Join-Path $distDir $item.Name
    Copy-Item -Force -LiteralPath $src -Destination $dst
    Write-Ok "staged : $($item.Name)"
}

# Caddyfile.windows is under config/ in the source tree. upgrade.ps1
# -IncludeCaddyfile expects config\Caddyfile.windows — which comes from
# `git pull`, not from the zip. We don't overwrite it from the zip to keep
# "git = source of truth for configs" clean.

# ---- Step 5: invoke upgrade.ps1 --------------------------------------------
Write-Step "upgrade.ps1"
$upgradeArgs = @{}
if ($IncludeCaddy)     { $upgradeArgs['IncludeCaddy']     = $true }
if ($IncludeCaddyfile) { $upgradeArgs['IncludeCaddyfile'] = $true }
& $upgradeScript @upgradeArgs
if ($LASTEXITCODE -ne 0) {
    throw "upgrade.ps1 failed. Inspect logs under $script:MiaLogsRelayDir."
}

# ---- Step 6: status summary ------------------------------------------------
Write-Step "status.ps1"
try {
    & $statusScript
} catch {
    Write-Warn2 "status.ps1 threw: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "==> apply-release complete." -ForegroundColor Green
Write-Host "    Staging preserved at: $stageDir"
Write-Host "    (safe to delete manually; kept for post-mortem if anything misbehaves)"
