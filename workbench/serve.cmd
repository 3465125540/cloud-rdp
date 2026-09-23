@echo off
REM ============================================================
REM  GitHub RDP workbench - start the server in the background
REM  (target of the desktop shortcut). Unlike start.cmd it does
REM  NOT open a browser and does NOT pause on failure, so it can
REM  run hidden. Log appends to %USERPROFILE%\cloud-rdp-workbench.log
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
  exit /b 1
)

set "LOG=%USERPROFILE%\cloud-rdp-workbench.log"
echo. >> "%LOG%"
echo [%DATE% %TIME%] start workbench (pid will be new) >> "%LOG%"
%PY% server.py --no-open %* >> "%LOG%" 2>&1
echo [%DATE% %TIME%] workbench exited >> "%LOG%"
endlocal
