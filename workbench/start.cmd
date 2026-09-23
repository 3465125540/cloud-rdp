@echo off
REM ============================================================
REM  Agent workbench - one-click start (double-click this file)
REM  Requires Python 3.8+. No third-party packages.
REM
REM  NOTE: keep this file pure ASCII. cmd.exe reads .cmd as ANSI
REM  (GBK on zh-CN Windows); UTF-8 Chinese can be mis-decoded and
REM  swallow a ')' or a quote, breaking the batch parser.
REM ============================================================
setlocal
cd /d "%~dp0"

set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY (
  where python >nul 2>nul && set "PY=python"
)
if not defined PY (
  echo [x] Python not found. Install Python 3.8+ and add it to PATH.
  pause
  exit /b 1
)

echo Starting agent workbench...
%PY% server.py %*
if errorlevel 1 (
  echo.
  echo [x] Start failed. See the error above.
  pause
)
endlocal
