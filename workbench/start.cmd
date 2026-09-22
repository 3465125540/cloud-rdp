@echo off
REM ============================================================
REM  智能体工作台 —— 一键启动（双击本文件）
REM  依赖：Python 3.8+（本机已装 3.13）。零第三方包。
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
  pause
  exit /b 1
)

echo 正在启动智能体工作台...
%PY% server.py %*
if errorlevel 1 (
  echo.
  echo [x] 启动失败，请看上方错误信息。
  pause
)
endlocal
