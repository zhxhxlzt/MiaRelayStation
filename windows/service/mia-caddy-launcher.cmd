@echo off
REM ============================================================================
REM Mia Caddy launcher (WinSW entry point)
REM
REM Same pattern as mia-relay-launcher.cmd:
REM   1. cwd to the config dir so any Caddy relative path resolves predictably.
REM   2. Load .env so MIA_DOMAIN is in the environment before Caddy starts;
REM      Caddyfile.windows references it as {$MIA_DOMAIN}.
REM   3. XDG_DATA_HOME is also set by the WinSW xml; re-asserted here in case
REM      a human runs this .cmd directly for smoke testing.
REM   4. Tail-call caddy.exe so WinSW owns the real process.
REM ============================================================================

setlocal EnableExtensions EnableDelayedExpansion

set "MIA_CONFIG_DIR=C:\ProgramData\Mia\config"
set "MIA_ENV_FILE=%MIA_CONFIG_DIR%\.env"
set "MIA_CADDY_EXE=C:\Program Files\Mia\caddy.exe"
set "MIA_CADDYFILE=C:\Program Files\Mia\Caddyfile.windows"

cd /d "%MIA_CONFIG_DIR%" || (
    echo [mia-caddy-launcher] FATAL: cannot cd to %MIA_CONFIG_DIR% 1>&2
    exit /b 2
)

if not exist "%MIA_ENV_FILE%" (
    echo [mia-caddy-launcher] FATAL: .env missing at %MIA_ENV_FILE% 1>&2
    exit /b 3
)

for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%MIA_ENV_FILE%") do (
    if not "%%A"=="" (
        set "%%A=%%B"
    )
)

if "%XDG_DATA_HOME%"=="" (
    set "XDG_DATA_HOME=C:\ProgramData\Mia\caddy"
)

if not exist "%MIA_CADDY_EXE%" (
    echo [mia-caddy-launcher] FATAL: caddy.exe missing at %MIA_CADDY_EXE% 1>&2
    exit /b 4
)
if not exist "%MIA_CADDYFILE%" (
    echo [mia-caddy-launcher] FATAL: Caddyfile.windows missing at %MIA_CADDYFILE% 1>&2
    exit /b 5
)

"%MIA_CADDY_EXE%" run --config "%MIA_CADDYFILE%" --adapter caddyfile
exit /b %ERRORLEVEL%
