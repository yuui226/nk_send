@echo off
rem ZTransfer license admin - double-click to open the interactive menu.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0admin.ps1"
if errorlevel 1 pause
