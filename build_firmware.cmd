@echo off
setlocal
cd /d "%~dp0"
if /I "%~1"=="-Fruit" goto unified
if /I "%~1"=="-Gesture" goto gesture
set "FIRMWARE_BUILD_ROOT=%~dp0"
pwsh.exe -NoProfile -Command "& (Join-Path $env:FIRMWARE_BUILD_ROOT 'verification\run_image_quality_build.ps1') -GenerateBit -ResourceLimits @{slice=21216;eram=108;dsp=40}"
exit /b %ERRORLEVEL%
:unified
set "FIRMWARE_BUILD_ROOT=%~dp0"
pwsh.exe -NoProfile -Command "& (Join-Path $env:FIRMWARE_BUILD_ROOT 'verification\run_image_quality_build.ps1') -GenerateBit -ResourceLimits @{slice=21216;eram=108;dsp=40}"
exit /b %ERRORLEVEL%
:gesture
powershell -NoProfile -ExecutionPolicy Bypass -File "verification/build_handfixed.ps1"
exit /b %ERRORLEVEL%
