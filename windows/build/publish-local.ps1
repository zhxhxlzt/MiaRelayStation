#Requires -Version 5.1
<#
.SYNOPSIS
  One-shot publish pipeline for Mia Cloud Relay → Windows Server.

.DESCRIPTION
  Two modes, selected by -BuildOnServer:

  (A) Default (zip-ship mode, pre-built on this machine):
    1. build-relay.ps1   → rebuild mia-relay.exe locally.
    2. release.ps1       → pack mia-relay-windows-<sha>.zip.
    3. (optional) git add/commit/push of cloud/windows/ source changes so the
       server can `git pull` and match the shipped exe.
    4. scp the zip to <SshTarget>:<RemoteDropDir> (default C:/Temp/mia-release).
    5. (optional) ssh <SshTarget> to run scripts\apply-release.ps1, which
       handles `git pull` + extract + upgrade.ps1 on the server side.

  (B) -BuildOnServer (source-ship mode, built on the server):
    1. git add/commit/push of cloud/windows/ source changes (always on in this
       mode — server pulls from origin, so commits must be upstream first).
    2. ssh <SshTarget> to run scripts\build-on-server.ps1, which on the server
       does: git pull → build-relay.ps1 → upgrade.ps1 → status.ps1.
    No local PyInstaller run, no zip, no scp. ~20 MB less network traffic;
    requires Python 3.11+ on the server (see bootstrap-server.ps1).

  Runs in an *elevated* PowerShell is NOT required locally — only building
  and scp are done here. Server-side steps require admin on the target.

.PARAMETER SshTarget
  user@host for the Windows Server. Required unless -SkipShip is set.

.PARAMETER SshKey
  Path to SSH private key. Optional; falls back to ssh-agent / default key.

.PARAMETER RemoteDropDir
  Directory on the server (in ssh-path form, e.g. C:/Temp/mia-release) where
  the zip will land. Default: C:/Temp/mia-release.

.PARAMETER RemoteApplyScript
  ssh-path to apply-release.ps1 on the server (zip mode). Default:
  C:/Deploy/cloud/cloud/windows/scripts/apply-release.ps1
  (layout: C:\Deploy\cloud is the cloned git repo root; inside it the project
   path is cloud/windows/scripts/apply-release.ps1)

.PARAMETER RemoteBuildScript
  ssh-path to build-on-server.ps1 on the server (source-ship mode). Default:
  C:/Deploy/cloud/cloud/windows/scripts/build-on-server.ps1

.PARAMETER BuildOnServer
  Use source-ship mode: skip local build/release/scp, git-push the source,
  and trigger build-on-server.ps1 remotely. Requires Python 3.11+ on the
  server. This is the recommended default for day-to-day code changes.

.PARAMETER Clean
  In -BuildOnServer mode: forwarded to build-on-server.ps1 / build-relay.ps1
  to wipe the server-side build venv before rebuilding. No effect otherwise.

.PARAMETER SkipBuild
  Do not rebuild mia-relay.exe. Useful when you only touched scripts/config.

.PARAMETER SkipGitPush
  Do not git add/commit/push. Useful when the working tree has unrelated
  changes you don't want shipped yet, or when there's nothing to push.

.PARAMETER SkipShip
  Stop after producing the zip; do not scp / ssh. Useful for dry runs.

.PARAMETER SkipRemoteApply
  scp the zip but do not remotely invoke apply-release.ps1. Operator will
  run it manually on the server (e.g. via RDP).

.PARAMETER IncludeCaddy
  Forwarded to server-side upgrade.ps1 — also upgrade caddy.exe.

.PARAMETER IncludeCaddyfile
  Forwarded to server-side upgrade.ps1 — also refresh Caddyfile.windows.

.PARAMETER CommitMessage
  Git commit message for step 4. Default: "chore(windows): ship <sha>".

.EXAMPLE
  # Source-ship mode (recommended): push source, build on server, upgrade.
  .\publish-local.ps1 -SshTarget Administrator@1.2.3.4 -BuildOnServer

.EXAMPLE
  # Zip-ship mode: full local pipeline, relay-only upgrade, default paths.
  .\publish-local.ps1 -SshTarget Administrator@1.2.3.4

.EXAMPLE
  # Zip-ship mode: only rebuild + pack + scp; run upgrade manually on server.
  .\publish-local.ps1 -SshTarget Administrator@1.2.3.4 -SkipRemoteApply

.EXAMPLE
  # Zip-ship mode: scripts-only change, no exe rebuild, upgrade Caddy too.
  .\publish-local.ps1 -SshTarget Administrator@1.2.3.4 -SkipBuild -IncludeCaddy
#>
[CmdletBinding()]
param(
    [string]$SshTarget,
    [string]$SshKey,
    [string]$RemoteDropDir     = 'C:/Temp/mia-release',
    [string]$RemoteApplyScript = 'C:/Deploy/cloud/cloud/windows/scripts/apply-release.ps1',
    [string]$RemoteBuildScript = 'C:/Deploy/cloud/cloud/windows/scripts/build-on-server.ps1',
    [switch]$BuildOnServer,
    [switch]$Clean,
    [switch]$SkipBuild,
    [switch]$SkipGitPush,
    [switch]$SkipShip,
    [switch]$SkipRemoteApply,
    [switch]$IncludeCaddy,
    [switch]$IncludeCaddyfile,
    [string]$CommitMessage
)

$ErrorActionPreference = 'Stop'

# ---- Paths ------------------------------------------------------------------
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $ScriptRoot       # cloud/windows/
$CloudRoot   = Split-Path -Parent $WindowsRoot      # cloud/
$RepoRoot    = Split-Path -Parent $CloudRoot        # repo root (parent of cloud/)

$BuildScript   = Join-Path $ScriptRoot 'build-relay.ps1'
$ReleaseScript = Join-Path $ScriptRoot 'release.ps1'
$ReleaseDir    = Join-Path $WindowsRoot 'release'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }

# ---- Pre-flight -------------------------------------------------------------
if ($BuildOnServer -and -not $SshTarget) {
    throw "-SshTarget <user@host> is required when using -BuildOnServer."
}
if (-not $BuildOnServer -and -not $SkipShip -and -not $SshTarget) {
    throw "-SshTarget <user@host> is required unless -SkipShip is set."
}

# Source-ship mode relies on the server pulling from origin, so git push
# is mandatory — silently override a stale -SkipGitPush.
if ($BuildOnServer -and $SkipGitPush) {
    Write-Warn2 "-BuildOnServer requires a successful git push; ignoring -SkipGitPush."
    $SkipGitPush = $false
}

# `git` must be available for sha, push, and `ssh git pull` on server.
try {
    $gitVersion = (& git --version) 2>&1
} catch {
    throw "git is not on PATH. Install Git for Windows or pass -SkipGitPush."
}

# SSH is needed in both modes that reach the server; scp only in zip mode.
$needSsh = $BuildOnServer -or (-not $SkipShip)
$needScp = (-not $BuildOnServer) -and (-not $SkipShip)
if ($needSsh -and -not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    throw "ssh.exe not found on PATH. Enable 'OpenSSH Client' in Windows Optional Features."
}
if ($needScp -and -not (Get-Command scp.exe -ErrorAction SilentlyContinue)) {
    throw "scp.exe not found on PATH. Enable 'OpenSSH Client' in Windows Optional Features, or use -BuildOnServer / -SkipShip."
}

# ---- Helper: build ssh arg array (shared by both modes) --------------------
function Build-SshArgs {
    $args = @()
    if ($SshKey) {
        if (-not (Test-Path -LiteralPath $SshKey)) { throw "SSH key not found: $SshKey" }
        $args += @('-i', $SshKey)
    }
    # StrictHostKeyChecking=accept-new: TOFU on first run instead of hanging.
    $args += @('-o', 'StrictHostKeyChecking=accept-new')
    return ,$args
}

# ==========================================================================
#  MODE B — source-ship (build on server)
# ==========================================================================
if ($BuildOnServer) {
    Write-Step "Mode: source-ship (build on server). Skipping local build/release/scp."
    $zip = $null  # sentinel so later commit message logic still works

    # --- B1: git push (mandatory in this mode) ---
    Write-Step "Step 1/2 · git add/commit/push cloud/windows/"
    $status = & git -C $RepoRoot status --porcelain -- 'cloud/windows/'
    if ([string]::IsNullOrWhiteSpace($status)) {
        Write-Warn2 "no tracked changes under cloud/windows/; will still push any unpushed commits."
    } else {
        & git -C $RepoRoot add 'cloud/windows/' | Out-Null
        if (-not $CommitMessage) {
            $headSha = (& git -C $RepoRoot rev-parse --short HEAD).Trim()
            $CommitMessage = "chore(windows): source-ship from $headSha"
        }
        & git -C $RepoRoot commit -m $CommitMessage | Out-Null
        $newSha = (& git -C $RepoRoot rev-parse --short HEAD).Trim()
        Write-Ok "committed: $newSha  ($CommitMessage)"
    }
    & git -C $RepoRoot push
    if ($LASTEXITCODE -ne 0) { throw "git push failed. Resolve manually and retry." }
    Write-Ok "pushed to origin."

    # --- B2: ssh → build-on-server.ps1 ---
    Write-Step "Step 2/2 · ssh → build-on-server.ps1 on server"
    $sshArgs = Build-SshArgs
    $remoteArgList = @()
    if ($Clean)            { $remoteArgList += '-Clean' }
    if ($IncludeCaddy)     { $remoteArgList += '-IncludeCaddy' }
    if ($IncludeCaddyfile) { $remoteArgList += '-IncludeCaddyfile' }
    $remoteCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$RemoteBuildScript`" $($remoteArgList -join ' ')".TrimEnd()
    & ssh @sshArgs $SshTarget $remoteCmd
    if ($LASTEXITCODE -ne 0) {
        throw "Remote build-on-server.ps1 exited non-zero. ssh into the server and inspect C:\ProgramData\Mia\logs\relay\ and the build output."
    }

    Write-Host ""
    Write-Host "==> Publish complete (source-ship)." -ForegroundColor Green
    Write-Host "    Server : $SshTarget"
    Write-Host "    Verify : curl https://<MIA_DOMAIN>/health"
    return
}

# ==========================================================================
#  MODE A — zip-ship (build locally, scp zip to server)
# ==========================================================================

# ---- Step 1: build ---------------------------------------------------------
if (-not $SkipBuild) {
    Write-Step "Step 1/5 · build-relay.ps1"
    & $BuildScript
    if ($LASTEXITCODE -ne 0) { throw "build-relay.ps1 failed." }
} else {
    Write-Step "Step 1/5 · build skipped (-SkipBuild)"
}

# ---- Step 2: release pack --------------------------------------------------
Write-Step "Step 2/5 · release.ps1"
& $ReleaseScript
if ($LASTEXITCODE -ne 0) { throw "release.ps1 failed." }

# Find the newest zip in release/.
$zip = Get-ChildItem -LiteralPath $ReleaseDir -Filter 'mia-relay-windows-*.zip' -File |
       Sort-Object LastWriteTime -Descending |
       Select-Object -First 1
if (-not $zip) { throw "No mia-relay-windows-*.zip found under $ReleaseDir after release.ps1." }
Write-Ok ("packed: {0} ({1:N2} MB)" -f $zip.Name, ($zip.Length / 1MB))

# ---- Step 3: git push cloud/windows/ ---------------------------------------
if (-not $SkipGitPush) {
    Write-Step "Step 3/5 · git add/commit/push cloud/windows/ (source + scripts)"

    # Only stage tracked changes under cloud/windows/ — dist/ and release/ are
    # already .gitignored, so nothing binary leaks in.
    $status = & git -C $RepoRoot status --porcelain -- 'cloud/windows/'
    if ([string]::IsNullOrWhiteSpace($status)) {
        Write-Warn2 "no tracked changes under cloud/windows/; skipping commit."
    } else {
        & git -C $RepoRoot add 'cloud/windows/' | Out-Null
        $sha = (& git -C $RepoRoot rev-parse --short HEAD).Trim()
        if (-not $CommitMessage) {
            # Embed the *new* zip tag, not the old HEAD sha.
            $zipTag = [IO.Path]::GetFileNameWithoutExtension($zip.Name)  # mia-relay-windows-<sha>
            $CommitMessage = "chore(windows): ship $zipTag"
        }
        & git -C $RepoRoot commit -m $CommitMessage | Out-Null
        $newSha = (& git -C $RepoRoot rev-parse --short HEAD).Trim()
        Write-Ok "committed: $newSha  ($CommitMessage)"
    }

    # Push regardless of whether we committed just now — there might be
    # local commits from earlier the user forgot to push.
    & git -C $RepoRoot push
    if ($LASTEXITCODE -ne 0) { throw "git push failed. Resolve manually and re-run with -SkipBuild -SkipGitPush to continue." }
    Write-Ok "pushed to origin."
} else {
    Write-Step "Step 3/5 · git push skipped (-SkipGitPush)"
}

# ---- Step 4: scp ------------------------------------------------------------
if ($SkipShip) {
    Write-Step "Step 4/5 · scp skipped (-SkipShip)"
    Write-Host ""
    Write-Host "Local zip ready at: $($zip.FullName)" -ForegroundColor Green
    return
}

Write-Step "Step 4/5 · scp $($zip.Name) → ${SshTarget}:${RemoteDropDir}/"

# Build ssh/scp arg arrays. `scp` needs the remote dir to exist; create it
# defensively with ssh first (mkdir -Force is idempotent in PowerShell).
$sshArgs = Build-SshArgs
$scpArgs = Build-SshArgs

# Ensure remote drop dir exists. We use PowerShell on the server side (default
# shell on modern Windows Server OpenSSH is cmd; invoke powershell explicitly).
$remoteMkdir = "powershell -NoProfile -Command `"New-Item -ItemType Directory -Force -Path '$RemoteDropDir' | Out-Null`""
& ssh @sshArgs $SshTarget $remoteMkdir
if ($LASTEXITCODE -ne 0) { throw "ssh mkdir on remote failed. Check -SshTarget / -SshKey / network." }

# scp the zip. Local path stays native (backslash), remote path ssh-style (forward slash).
& scp @scpArgs $zip.FullName ("{0}:{1}/{2}" -f $SshTarget, $RemoteDropDir, $zip.Name)
if ($LASTEXITCODE -ne 0) { throw "scp failed." }
Write-Ok "uploaded: ${RemoteDropDir}/$($zip.Name)"

# ---- Step 5: remote apply --------------------------------------------------
if ($SkipRemoteApply) {
    Write-Step "Step 5/5 · remote apply skipped (-SkipRemoteApply)"
    Write-Host ""
    Write-Host "Next on the server (elevated PowerShell):" -ForegroundColor Yellow
    $applyCmd = "& '$RemoteApplyScript' -ZipPath '$RemoteDropDir/$($zip.Name)'"
    if ($IncludeCaddy)     { $applyCmd += ' -IncludeCaddy' }
    if ($IncludeCaddyfile) { $applyCmd += ' -IncludeCaddyfile' }
    Write-Host "  $applyCmd"
    return
}

Write-Step "Step 5/5 · ssh → apply-release.ps1 on server"

# Compose the remote command. We must pass through switches to apply-release.ps1.
$applyArgs = @("-ZipPath", "'$RemoteDropDir/$($zip.Name)'")
if ($IncludeCaddy)     { $applyArgs += '-IncludeCaddy' }
if ($IncludeCaddyfile) { $applyArgs += '-IncludeCaddyfile' }

# Caller must have admin on the server; we don't try to UAC-elevate over ssh
# (impossible without interactive consent). If the logged-in ssh user is not
# an admin, apply-release.ps1's Assert-Administrator will bail clearly.
$remoteCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$RemoteApplyScript`" $($applyArgs -join ' ')"
& ssh @sshArgs $SshTarget $remoteCmd
if ($LASTEXITCODE -ne 0) {
    throw "Remote apply-release.ps1 exited non-zero. ssh into the server and inspect `C:\ProgramData\Mia\logs\relay\` for details."
}

Write-Host ""
Write-Host "==> Publish complete." -ForegroundColor Green
Write-Host "    Zip    : $($zip.Name)"
Write-Host "    Server : $SshTarget"
Write-Host "    Verify : curl https://<MIA_DOMAIN>/health"
