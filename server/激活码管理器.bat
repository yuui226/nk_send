@echo off
rem ZTransfer modern license admin UI. The legacy CLI launcher remains unchanged.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0admin-gui.ps1"
exit /b 0
