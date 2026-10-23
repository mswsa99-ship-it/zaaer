@echo off
rem Zaaer - branch WhatsApp on the reception computer. Keeps the program running; restarts it if it stops.
setlocal
chcp 65001 >nul
title Zaaer - Branch WhatsApp
cd /d "%~dp0"
set "PUPPETEER_SKIP_DOWNLOAD=1"
set "NODE=%~dp0node\node.exe"
if not exist "%NODE%" set "NODE=node"
:loop
"%NODE%" "%~dp0src\index.mjs"
set "CODE=%ERRORLEVEL%"
if "%CODE%"=="0" goto end
if "%CODE%"=="2" goto needs_action
echo.
echo Restarting in 10 seconds... (close this window to stop)
timeout /t 10 /nobreak >nul
goto loop
:needs_action
echo.
echo Please read the message above (also in the logs folder), fix it, then run start.bat again.
pause
:end
endlocal
