@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "verification/build_handfixed.ps1" %*
if errorlevel 1 pause
