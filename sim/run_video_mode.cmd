@echo off
setlocal
set "SIM_BIN=D:\XILINX\Vivado\2021.1\bin"
if defined VIVADO_SIM_BIN set "SIM_BIN=%VIVADO_SIM_BIN%"
if not exist "%SIM_BIN%\xvlog.bat" (
    echo XSim not found. Set VIVADO_SIM_BIN or edit SIM_BIN.
    if /I not "%~1"=="--no-pause" pause
    exit /b 1
)
set "SIM_SRC=%~dp0"
for %%I in ("%~dp0..") do set "PROJECT_ROOT=%%~fI"
for /f %%G in ('powershell.exe -NoProfile -Command "[guid]::NewGuid().ToString('N')"') do set "SIM_OUT=%TEMP%\anlogic_video_mode_%%G"
set "SIZE_PARAMS="
if /I "%~2"=="720" (
    set "SIZE_PARAMS=-generic_top "WIDTH=1280" -generic_top "HEIGHT=720" -generic_top "FAST=1""
)
if /I "%~2"=="odd" (
    set "SIZE_PARAMS=-generic_top "HEIGHT=49""
)
if /I "%~2"=="no-gaussian" (
    set "SIZE_PARAMS=-generic_top "GAUSSIAN_ENABLE=0""
)
mkdir "%SIM_OUT%"
if errorlevel 1 exit /b 1
pushd "%SIM_OUT%"
if errorlevel 1 exit /b 1
>result.txt echo RUNNING
call "%SIM_BIN%\xvlog.bat" -sv -d SCHARR_PORTABLE_RAM "%PROJECT_ROOT%\user_source\hdl_source\video_mode_control.v" "%PROJECT_ROOT%\user_source\hdl_source\isp\rgb_edge_switch_96.v" "%PROJECT_ROOT%\user_source\hdl_source\isp\scharr_edge_detect_96.v" "%SIM_SRC%tb_video_mode_control.sv" "%SIM_SRC%tb_scharr_edge_detect_96.sv" -log xvlog.log >compile_console.log 2>&1
if errorlevel 1 goto failed
call "%SIM_BIN%\xelab.bat" -timescale 1ns/1ps work.tb_video_mode_control -s mode_button_sim -log button_elab.log >button_elab_console.log 2>&1
if errorlevel 1 goto failed
call "%SIM_BIN%\xsim.bat" mode_button_sim -runall -log button_sim.log >button_console.log 2>&1
if errorlevel 1 goto failed
findstr /c:"VIDEO_MODE_BUTTON_TEST_PASS" button_console.log >nul
if errorlevel 1 goto failed
call "%SIM_BIN%\xelab.bat" -timescale 1ns/1ps %SIZE_PARAMS% work.tb_scharr_edge_detect_96 -s color_video_mode -log video_elab.log >video_elab_console.log 2>&1
if errorlevel 1 goto failed
call "%SIM_BIN%\xsim.bat" color_video_mode -runall -log video_sim.log >video_console.log 2>&1
if errorlevel 1 goto failed
findstr /c:"SCHARR_EDGE_TEST_PASS" video_console.log >nul
if errorlevel 1 goto failed
findstr /c:"EMBOSS_TEST_PASS" video_console.log >nul
if errorlevel 1 goto failed
findstr /c:"CARTOON_TEST_PASS" video_console.log >nul
if errorlevel 1 goto failed
findstr /c:"INVERSE_SCHARR_SELECTOR_TEST_PASS" video_console.log >nul
if errorlevel 1 goto failed
findstr /c:"MORPHOLOGY_TEST_PASS" video_console.log >nul
if errorlevel 1 goto failed
>result.txt echo PASS
type result.txt
findstr /c:"VIDEO_MODE_BUTTON_TEST_PASS" button_console.log
findstr /c:"SCHARR_EDGE_TEST_PASS" /c:"SCHARR_CONTOURS" /c:"EMBOSS_TEST_PASS" /c:"EMBOSS_SYNTHETIC_PREVIEW" /c:"CARTOON_TEST_PASS" /c:"CARTOON_SYNTHETIC_PREVIEW" /c:"INVERSE_SCHARR_SELECTOR_TEST_PASS" /c:"MORPHOLOGY_TEST_PASS" /c:"MORPHOLOGY_SYNTHETIC_PREVIEW" video_console.log
echo Simulation output: %SIM_OUT%
popd
if /I not "%~1"=="--no-pause" pause
exit /b 0
:failed
>result.txt echo FAIL
echo Video mode simulation FAILED. Read %SIM_OUT% logs.
popd
if /I not "%~1"=="--no-pause" pause
exit /b 1
