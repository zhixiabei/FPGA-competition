@echo off
setlocal
cd /d "%~dp0"
if not "%~1"=="" if /I not "%~1"=="-Fruit" (
    echo Only the unified main project is supported. Usage: build_firmware.cmd [-Fruit]
    exit /b 2
)
set "FIRMWARE_BUILD_ROOT=%~dp0"
pwsh.exe -NoProfile -Command "& (Join-Path $env:FIRMWARE_BUILD_ROOT 'verification\run_image_quality_build.ps1') -GenerateBit -ResourceLimits @{slice=21216;eram=108;dsp=40}"
exit /b %ERRORLEVEL%
