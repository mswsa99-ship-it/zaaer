@echo off
rem Starts the branch WhatsApp program with Windows (a shortcut in the Startup folder, minimised).
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$w = New-Object -ComObject WScript.Shell; $s = $w.CreateShortcut([IO.Path]::Combine([Environment]::GetFolderPath('Startup'), 'Zaaer WhatsApp.lnk')); $s.TargetPath = '%~dp0start.bat'; $s.WorkingDirectory = '%~dp0'; $s.WindowStyle = 7; $s.Save()"
if errorlevel 1 (
  echo Could not create the startup shortcut.
) else (
  echo Done: the program will start with Windows.
)
pause
endlocal
