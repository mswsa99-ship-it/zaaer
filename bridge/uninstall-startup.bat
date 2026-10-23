@echo off
rem Stops the branch WhatsApp program from starting with Windows.
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Zaaer WhatsApp.lnk" 2>nul
echo Done: the program will no longer start with Windows.
pause
