#Requires -Version 5.1
<#
.SYNOPSIS
  Package a Mia Cloud Relay Windows release zip for hand-off to the operator.

.DESCRIPTION
  Preconditions (script will error out if not satisfied):
    * cloud/windows/dist/mia-relay.exe   (produced by build-relay.ps1)
    * cloud/windows/dist/caddy.exe       (downloaded by operator/dev)
    * cloud/windows/dist/winsw.exe       (downloaded by operator/dev)

  Produces:
    * cloud/windows/release/mia-relay-windows-<git-short-sha>.zip

  The zip layout is flattened — install.ps1 is written to accept both the
  dev tree and the flattened release tree, so no nested dist/service/config
  directories exist in the zip.

.NOTES
  This is NOT a build script; it does not invoke PyInstaller. Run
  build-relay.ps1 first to produce mia-relay.exe.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ---- Paths ------------------------------------------------------------------
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $ScriptRoot       # cloud/windows/
$CloudRoot   = Split-Path -Parent $WindowsRoot      # cloud/
$RepoRoot    = Split-Path -Parent $CloudRoot

$DistDir     = Join-Path $WindowsRoot 'dist'
$ReleaseDir  = Join-Path $WindowsRoot 'release'

# ---- Preconditions ---------------------------------------------------------
$required = @(
    @{ Name='mia-relay.exe';       Path=(Join-Path $DistDir 'mia-relay.exe');       Fix='Run cloud\windows\build\build-relay.ps1 first.' }
    @{ Name='caddy.exe';           Path=(Join-Path $DistDir 'caddy.exe');           Fix='Download caddy_windows_amd64.zip from https://caddyserver.com/download and drop caddy.exe into cloud\windows\dist\.' }
    @{ Name='winsw.exe';           Path=(Join-Path $DistDir 'winsw.exe');           Fix='Download the latest WinSW-x64.exe from https://github.com/winsw/winsw/releases and rename to winsw.exe under cloud\windows\dist\.' }
)
$missing = $required | Where-Object { -not (Test-Path -LiteralPath $_.Path) }
if ($missing.Count -gt 0) {
    Write-Host "Missing required binaries:" -ForegroundColor Red
    foreach ($m in $missing) {
        Write-Host ("  {0,-15}  expected at {1}" -f $m.Name, $m.Path) -ForegroundColor Red
        Write-Host ("                   -> {0}" -f $m.Fix) -ForegroundColor Yellow
    }
    throw "Cannot package release: binaries missing."
}

# ---- Git short sha ---------------------------------------------------------
$sha = try {
    (& git -C $RepoRoot rev-parse --short HEAD 2>$null).Trim()
} catch {
    $null
}
if (-not $sha) {
    $sha = 'local{0:yyyyMMddHHmmss}' -f (Get-Date)
    Write-Host "git sha unavailable; using fallback tag '$sha'" -ForegroundColor Yellow
}

$packageName = "mia-relay-windows-$sha"
$stagingDir  = Join-Path $ReleaseDir $packageName
$zipPath     = Join-Path $ReleaseDir "$packageName.zip"

if (Test-Path -LiteralPath $stagingDir) { Remove-Item -Recurse -Force $stagingDir }
if (Test-Path -LiteralPath $zipPath)    { Remove-Item -Force $zipPath }

New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

# ---- Layout ----------------------------------------------------------------
# Flatten service/, config/, scripts/, dist/ into the zip root. install.ps1
# already tolerates this layout via its Resolve-SourceFile fallbacks.
function Copy-Many {
    param([string]$SrcDir, [string[]]$Files, [string]$DstDir)
    foreach ($f in $Files) {
        $src = Join-Path $SrcDir $f
        if (-not (Test-Path -LiteralPath $src)) { throw "release.ps1: source missing: $src" }
        Copy-Item -Force -LiteralPath $src -Destination (Join-Path $DstDir $f)
    }
}

Copy-Many -SrcDir $DistDir -Files @('mia-relay.exe','caddy.exe','winsw.exe') -DstDir $stagingDir
Copy-Many -SrcDir (Join-Path $WindowsRoot 'service') -Files @(
    'mia-relay.xml','mia-caddy.xml','mia-relay-launcher.cmd','mia-caddy-launcher.cmd'
) -DstDir $stagingDir
Copy-Many -SrcDir (Join-Path $WindowsRoot 'config') -Files @(
    'Caddyfile.windows','env.example'
) -DstDir $stagingDir

# scripts/ keeps its own dir so operators run `.\scripts\install.ps1`.
$dstScripts = Join-Path $stagingDir 'scripts'
New-Item -ItemType Directory -Force -Path $dstScripts | Out-Null
Copy-Many -SrcDir (Join-Path $WindowsRoot 'scripts') -Files @(
    'common.ps1','install.ps1','upgrade.ps1','uninstall.ps1','status.ps1','apply-release.ps1','build-on-server.ps1'
) -DstDir $dstScripts

Copy-Item -Force -LiteralPath (Join-Path $WindowsRoot 'README.md') -Destination (Join-Path $stagingDir 'README.md')

# ---- Zip --------------------------------------------------------------------
Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $zipPath -CompressionLevel Optimal

# Clean staging; keep the zip.
Remove-Item -Recurse -Force -LiteralPath $stagingDir

# ---- Report -----------------------------------------------------------------
$size   = (Get-Item -LiteralPath $zipPath).Length
$sizeMB = [math]::Round($size / 1MB, 2)
$hash   = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash

Write-Host ""
Write-Host "==> Release packaged" -ForegroundColor Green
Write-Host "    Path   : $zipPath"
Write-Host "    Size   : $sizeMB MB"
Write-Host "    SHA256 : $hash"
Write-Host ""
Write-Host "Hand off to ops:"
Write-Host "  1. Copy this zip to the target Windows Server."
Write-Host "  2. Right-click > Properties > Unblock (removes 'mark of the web')."
Write-Host "  3. Extract to any directory."
Write-Host "  4. From elevated PowerShell in that dir: .\scripts\install.ps1"
