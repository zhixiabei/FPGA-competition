@echo off
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verification\run_image_quality_build.ps1" -GenerateBit
set "FIRMWARE_BUILD_EXIT=%ERRORLEVEL%"
if "%FIRMWARE_BUILD_EXIT%"=="0" (
    echo.
    echo Programming file: "%~dp0td_project\anlogic_edge_osd_Runs\best_result\anlogic_edge_osd.bit"
    echo Identical copy: "%~dp0firmware\anlogic_edge_osd.bit"
) else (
    echo.
    echo Build failed. The previous programming file was preserved.
)
popd
pause
exit /b %FIRMWARE_BUILD_EXIT%
