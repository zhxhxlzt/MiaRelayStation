#Requires -Version 5.1
<#
.SYNOPSIS
  Shared helpers for Mia Cloud Relay Windows install / upgrade / uninstall scripts.

.DESCRIPTION
  This file is dot-sourced by install.ps1 / upgrade.ps1 / uninstall.ps1 /
  status.ps1. It centralizes path constants, privilege checks, directory &
  ACL management, firewall rule management, and health-readiness polling so
  the top-level scripts stay small and readable.

  All functions use `throw` on fatal errors; callers should rely on
  $ErrorActionPreference='Stop' (set at the top of each top-level script) to
  abort without continuing past a bad state.

.NOTES
  Do not execute this file directly; it is a helper library.
#>

# ---- Constants --------------------------------------------------------------

# Public root for installed binaries + configs (Caddyfile, xml, launchers).
$script:MiaInstallRoot    = 'C:\Program Files\Mia'
$script:MiaInstallBinDir  = Join-Path $script:MiaInstallRoot 'bin'

# Runtime variable data root (secrets, certificates, logs).
$script:MiaDataRoot       = 'C:\ProgramData\Mia'
$script:MiaConfigDir      = Join-Path $script:MiaDataRoot 'config'
$script:MiaEnvFile        = Join-Path $script:MiaConfigDir '.env'
$script:MiaCaddyDataDir   = Join-Path $script:MiaDataRoot 'caddy'
$script:MiaLogsRelayDir   = Join-Path $script:MiaDataRoot 'logs\relay'
$script:MiaLogsCaddyDir   = Join-Path $script:MiaDataRoot 'logs\caddy'

# Firewall rule name prefix used for grouping/cleanup.
$script:MiaFirewallPrefix = 'Mia-'

# Service names (must match WinSW <id> in service/*.xml).
$script:MiaRelayService   = 'MiaRelay'
$script:MiaCaddyService   = 'MiaCaddy'

# ---- Privilege & prerequisite checks ----------------------------------------

function Assert-Administrator {
    <#
    .SYNOPSIS Refuse to run unless the current process is elevated.
    #>
    $id    = [Security.Principal.WindowsIdentity]::GetCurrent()
    $prin  = New-Object Security.Principal.WindowsPrincipal($id)
    $admin = [Security.Principal.WindowsBuiltInRole]::Administrator
    if (-not $prin.IsInRole($admin)) {
        throw "This script must be run from an ELEVATED PowerShell (Run as Administrator)."
    }
}

function Assert-DotNetFramework48 {
    <#
    .SYNOPSIS Verify .NET Framework >= 4.8 is installed (WinSW v3 requires it).
    .NOTES   Release value 528040 corresponds to .NET 4.8 per MS docs.
    #>
    $key = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    if (-not (Test-Path $key)) {
        throw ".NET Framework 4 not detected. WinSW v3 requires .NET Framework 4.8+."
    }
    $release = (Get-ItemProperty $key -ErrorAction Stop).Release
    if (-not $release -or $release -lt 528040) {
        throw ".NET Framework 4.8+ required (found release=$release). Install .NET Framework 4.8 and retry."
    }
}

# ---- Directories & ACL ------------------------------------------------------

function Ensure-Directory {
    <#
    .SYNOPSIS Idempotent directory creation.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Set-SecureConfigAcl {
    <#
    .SYNOPSIS
      Restrict ACL on the config directory (holding .env with tokens) to
      SYSTEM + Administrators only. Disables inheritance so user ACLs on
      ProgramData do not leak into here.
    .PARAMETER Path Directory whose ACL is rewritten.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Set-SecureConfigAcl: path does not exist: $Path"
    }

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)  # protected, do not copy inherited

    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $propagate = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    foreach ($principal in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $principal, $rights, $inherit, $propagate, $allow)
        $acl.AddAccessRule($rule)
    }

    # Set the owner to Administrators so future ACL edits don't require takeown.
    $owner = New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')
    $acl.SetOwner($owner)

    Set-Acl -LiteralPath $Path -AclObject $acl
}

# ---- Firewall ---------------------------------------------------------------

function Set-MiaFirewallRules {
    <#
    .SYNOPSIS
      Create (idempotently) the Mia-* inbound firewall rules:
        * Mia-Allow-HTTP   : TCP 80 allow
        * Mia-Allow-HTTPS  : TCP 443 allow
        * Mia-Block-Relay  : TCP 8000 block (double-safety)
    #>
    $rules = @(
        @{ Name='Mia-Allow-HTTP';  Port=80;   Action='Allow'; Desc='Mia Caddy HTTP (ACME challenge + HTTPS redirect)' }
        @{ Name='Mia-Allow-HTTPS'; Port=443;  Action='Allow'; Desc='Mia Caddy HTTPS / WSS' }
        @{ Name='Mia-Block-Relay'; Port=8000; Action='Block'; Desc='Mia Relay MUST only be reachable via loopback' }
    )
    foreach ($r in $rules) {
        $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
        if ($existing) {
            # Re-assert params in case someone tweaked them manually.
            # Note: Set-NetFirewallPortFilter -AssociatedNetFirewallRule is not supported
            # on all Windows versions; use Remove+New to update port if needed.
            Set-NetFirewallRule -DisplayName $r.Name `
                -Direction Inbound -Action $r.Action -Protocol TCP `
                -LocalPort $r.Port -Enabled True | Out-Null
        } else {
            New-NetFirewallRule -DisplayName $r.Name `
                -Description $r.Desc `
                -Direction Inbound -Action $r.Action `
                -Protocol TCP -LocalPort $r.Port -Enabled True | Out-Null
        }
    }
}

function Remove-MiaFirewallRules {
    <#
    .SYNOPSIS Remove all Mia-* firewall rules (by name prefix).
    #>
    Get-NetFirewallRule -DisplayName "$($script:MiaFirewallPrefix)*" -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

# ---- Port occupancy --------------------------------------------------------

function Get-PortOccupants {
    <#
    .SYNOPSIS  Find processes currently listening on the given TCP ports.
    .OUTPUTS   Array of [pscustomobject] with Port/PID/ProcessName, or empty array.
    #>
    param([Parameter(Mandatory)][int[]]$Ports)

    $results = @()
    foreach ($p in $Ports) {
        $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        foreach ($c in $conns) {
            $procName = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            $results += [pscustomobject]@{
                Port        = $p
                PID         = $c.OwningProcess
                ProcessName = $procName
            }
        }
    }
    return $results
}

# ---- Health readiness polling ----------------------------------------------

function Wait-HealthReady {
    <#
    .SYNOPSIS
      Poll a URL every 1s until it returns HTTP 200, or until timeout.
    .PARAMETER Url
      Full URL, e.g. http://127.0.0.1:8000/health .
    .PARAMETER TimeoutSeconds
      Budget in seconds. 30 is typical for local, 120 when awaiting first ACME.
    .OUTPUTS
      $true on success; throws on timeout.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            # -UseBasicParsing avoids IE engine dependency on Server Core.
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                return $true
            }
        } catch {
            # Not ready yet; keep polling.
        }
        Start-Sleep -Seconds 1
    }
    throw "Wait-HealthReady: $Url did not return 200 within $TimeoutSeconds s."
}
