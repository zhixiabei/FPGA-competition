@echo off
cd /d "%~dp0"
python "verification\run_handfixed_gesture.py" %*
if errorlevel 1 pause
