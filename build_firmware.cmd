@echo off
setlocal
pushd "%~dp0"
set "FIRMWARE_BUILD_ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& (Join-Path $env:FIRMWARE_BUILD_ROOT 'verification\run_image_quality_build.ps1') -GenerateBit -ResourceLimits @{slice=17706;lut6=17508;reg=17225;eram=79;dsp=15}"
set "BIT_BUILD_EXIT=%ERRORLEVEL%"
if "%BIT_BUILD_EXIT%"=="0" (
    echo.
    echo Programming file: "%~dp0td_project\anlogic_edge_osd_Runs\best_result\anlogic_edge_osd.bit"
) else (
    echo.
    echo Build failed. The previous programming file was preserved.
)
popd
pause
exit /b %BIT_BUILD_EXIT%
