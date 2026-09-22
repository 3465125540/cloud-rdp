@echo off
REM ============================================================
REM  GitHub 虚拟机管理工作台 —— 后台启动服务（供桌面快捷方式调用）
REM  与 start.cmd 的区别：不自动开浏览器、失败不 pause（要能隐藏跑）。
REM  日志追加到 %USERPROFILE%\cloud-rdp-workbench.log
REM ============================================================
setlocal
cd /d "%~dp0"

set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY (
  where python >nul 2>nul && set "PY=python"
)
if not defined PY (
  echo [x] 没找到 Python，请先安装 Python 3.8+ 并加入 PATH。
  exit /b 1
)

set "LOG=%USERPROFILE%\cloud-rdp-workbench.log"
echo. >> "%LOG%"
echo [%DATE% %TIME%] start workbench (pid will be new) >> "%LOG%"
%PY% server.py --no-open %* >> "%LOG%" 2>&1
echo [%DATE% %TIME%] workbench exited >> "%LOG%"
endlocal
