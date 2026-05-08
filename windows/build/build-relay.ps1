#Requires -Version 5.1
<#
.SYNOPSIS
  Build Mia Cloud Relay as a single-file Windows executable via PyInstaller.

.DESCRIPTION
  Intended to run on Windows 11 (dev) or Windows Server 2019+ (server-side
  build) with Python 3.11+ already installed and on PATH. Produces
  `cloud/windows/dist/mia-relay.exe`.

  Idempotent:
    * Re-creates the build venv only if missing or if -Clean is passed.
    * Re-installs deps on every run (pip is fast for already-satisfied deps).
    * Overwrites mia-relay.exe on every run.

.PARAMETER Clean
  If set, deletes the build venv before starting. Use this if deps drift or
  PyInstaller caches cause weird failures.

.NOTES
  The PyInstaller spec is cloud/windows/build/mia-relay.spec. See that file
  for hiddenimports / excludes rationale.
#>
[CmdletBinding()]
param(
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

# ---- Paths ------------------------------------------------------------------

# Build script lives in cloud/windows/build/. Resolve everything from here.
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $ScriptRoot            # cloud/windows/
$CloudRoot   = Split-Path -Parent $WindowsRoot           # cloud/
$RepoRoot    = Split-Path -Parent $CloudRoot             # repo root

$VenvDir     = Join-Path $WindowsRoot '.build-venv'
$DistDir     = Join-Path $WindowsRoot 'dist'
$SpecPath    = Join-Path $ScriptRoot  'mia-relay.spec'
$BuildWork   = Join-Path $ScriptRoot  'build'   # PyInstaller work dir
$BuildOut    = Join-Path $ScriptRoot  'dist'    # PyInstaller dist dir (temp)

# ---- Pre-flight -------------------------------------------------------------

Write-Host "==> Mia Relay Windows build" -ForegroundColor Cyan
Write-Host "    Repo root    : $RepoRoot"
Write-Host "    Spec file    : $SpecPath"
Write-Host "    Output dir   : $DistDir"

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    throw "Python not found on PATH. Install Python 3.11+ and re-run."
}

$pyVersion = & python --version 2>&1
Write-Host "    Python       : $pyVersion"

if (-not (Test-Path $SpecPath)) {
    throw "Spec file missing: $SpecPath"
}

# ---- Venv -------------------------------------------------------------------

if ($Clean -and (Test-Path $VenvDir)) {
    Write-Host "==> -Clean: removing existing venv $VenvDir" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $VenvDir
}

if (-not (Test-Path $VenvDir)) {
    Write-Host "==> Creating build venv at $VenvDir" -ForegroundColor Cyan
    & python -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw "venv creation failed (exit=$LASTEXITCODE)" }
}

$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
$VenvPip    = Join-Path $VenvDir 'Scripts\pip.exe'

if (-not (Test-Path $VenvPython)) {
    throw "venv looks broken (no python.exe at $VenvPython). Re-run with -Clean."
}

Write-Host "==> Upgrading pip/setuptools/wheel in venv" -ForegroundColor Cyan
& $VenvPython -m pip install --upgrade pip setuptools wheel | Out-Host
if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed" }

# Install the mia-relay project (pulls fastapi/uvicorn/websockets/etc. from
# pyproject.toml). Install non-editable so PyInstaller can resolve the package
# by its installed location rather than an egg-link.
Write-Host "==> Installing mia-relay from $CloudRoot" -ForegroundColor Cyan
& $VenvPip install --disable-pip-version-check $CloudRoot | Out-Host
if ($LASTEXITCODE -ne 0) { throw "pip install mia-relay failed" }

# Install PyInstaller in the same venv.
Write-Host "==> Installing pyinstaller" -ForegroundColor Cyan
& $VenvPip install --disable-pip-version-check 'pyinstaller>=6.0,<7.0' | Out-Host
if ($LASTEXITCODE -ne 0) { throw "pip install pyinstaller failed" }

# ---- Build ------------------------------------------------------------------

# Ensure dist dir exists; clear previous artifact so we never silently ship stale exe.
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$TargetExe = Join-Path $DistDir 'mia-relay.exe'
if (Test-Path $TargetExe) {
    Remove-Item -Force $TargetExe
}

Write-Host "==> Running PyInstaller" -ForegroundColor Cyan
Push-Location $ScriptRoot
try {
    & $VenvPython -m PyInstaller --clean --noconfirm `
        --distpath $BuildOut `
        --workpath $BuildWork `
        $SpecPath | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed (exit=$LASTEXITCODE)" }
}
finally {
    Pop-Location
}

$ProducedExe = Join-Path $BuildOut 'mia-relay.exe'
if (-not (Test-Path $ProducedExe)) {
    throw "PyInstaller finished but $ProducedExe not found."
}

# Move to cloud/windows/dist/ as the stable output location.
Move-Item -Force $ProducedExe $TargetExe

# Clean up PyInstaller intermediate dirs to keep cloud/windows/build/ tidy.
foreach ($tmp in @($BuildOut, $BuildWork)) {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
}

# ---- Report -----------------------------------------------------------------

$size    = (Get-Item $TargetExe).Length
$sizeMB  = [math]::Round($size / 1MB, 2)
$hashObj = Get-FileHash -Algorithm SHA256 $TargetExe

Write-Host ""
Write-Host "==> Build complete" -ForegroundColor Green
Write-Host "    Path   : $TargetExe"
Write-Host "    Size   : $sizeMB MB"
Write-Host "    SHA256 : $($hashObj.Hash)"
Write-Host ""
Write-Host "Smoke test (in a fresh PowerShell):" -ForegroundColor Yellow
Write-Host "    `$env:MIA_AUTH_TOKENS='dev-local'; `$env:MIA_RELAY_PORT='8001'"
Write-Host "    & '$TargetExe'"
Write-Host "    # then in another shell: curl http://127.0.0.1:8001/health"
