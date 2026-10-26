@echo off
setlocal
cd /d "%~dp0"
if /I "%~1"=="-Fruit" goto fruit
if /I "%~1"=="-Gesture" goto gesture
set "FIRMWARE_BUILD_ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& (Join-Path $env:FIRMWARE_BUILD_ROOT 'verification\run_image_quality_build.ps1') -GenerateBit -ResourceLimits @{slice=17706;lut6=17508;reg=17225;eram=79;dsp=15}"
exit /b %ERRORLEVEL%
:fruit
if not exist "build\fruit\td_main_sw2\handfixed_candidate.al" (
    echo Prepare the merged SW2 fruit project first. See docs\MASTER_MAIN_MERGE.md.
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "verification/build_handfixed.ps1" -Fruit -Project "build/fruit/td_main_sw2"
exit /b %ERRORLEVEL%
:gesture
powershell -NoProfile -ExecutionPolicy Bypass -File "verification/build_handfixed.ps1"
exit /b %ERRORLEVEL%
