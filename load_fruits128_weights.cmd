@echo off
setlocal
cd /d "%~dp0"
"%~dp0.conda\fruitcuda\python.exe" "%~dp0verification\check_fruit128_release.py" --project "%~dp0build\fruit\td" --physical
if errorlevel 1 exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verification\load_handfixed_uart.ps1" -Fruit -WinUsb -Model "%~dp0build\fruit\weights\model.bin" -Project "%~dp0build\fruit\td" %*
exit /b %ERRORLEVEL%
