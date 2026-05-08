@echo off
REM ============================================================================
REM Mia Cloud Relay launcher (WinSW entry point)
REM
REM Responsibilities:
REM   1. Move cwd to the config directory so python-dotenv finds .env
REM      without the relay main.py having to know the path.
REM   2. Parse .env line-by-line and `set` each KEY=VALUE into the process
REM      environment. This keeps secrets (MIA_AUTH_TOKENS) out of the WinSW
REM      xml committed to git.
REM   3. Tail-call the PyInstaller onefile exe. No "start" / no new cmd window
REM      so WinSW sees the real process and can manage its lifecycle.
REM
REM .env format contract (see env.example):
REM   - One KEY=VALUE per line
REM   - No quotes around values
REM   - Lines starting with '#' are comments and ignored
REM   - Blank lines are ignored
REM   - Values may contain '=' (tokens=VALUE after the first '=')
REM ============================================================================

setlocal EnableExtensions EnableDelayedExpansion

set "MIA_CONFIG_DIR=C:\ProgramData\Mia\config"
set "MIA_ENV_FILE=%MIA_CONFIG_DIR%\.env"
set "MIA_RELAY_EXE=C:\Program Files\Mia\mia-relay.exe"

cd /d "%MIA_CONFIG_DIR%" || (
    echo [mia-relay-launcher] FATAL: cannot cd to %MIA_CONFIG_DIR% 1>&2
    exit /b 2
)

if not exist "%MIA_ENV_FILE%" (
    echo [mia-relay-launcher] FATAL: .env missing at %MIA_ENV_FILE% 1>&2
    exit /b 3
)

REM Load .env: skip comments, split on first '='.
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%MIA_ENV_FILE%") do (
    if not "%%A"=="" (
        set "%%A=%%B"
    )
)

if not exist "%MIA_RELAY_EXE%" (
    echo [mia-relay-launcher] FATAL: relay exe missing at %MIA_RELAY_EXE% 1>&2
    exit /b 4
)

REM Exec the relay. WinSW will capture stdout/stderr to the rolling log file.
"%MIA_RELAY_EXE%"
exit /b %ERRORLEVEL%
