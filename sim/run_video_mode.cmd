@echo off
setlocal
set "SIM_BIN=D:\XILINX\Vivado\2021.1\bin"
if defined VIVADO_SIM_BIN set "SIM_BIN=%VIVADO_SIM_BIN%"
pushd "%~dp0"
set "SIM_OUT=out_video_mode"
set "SIZE_PARAMS="
if /I "%~2"=="720" (
    set "SIM_OUT=out_video_mode_720p"
    set "SIZE_PARAMS=-generic_top "WIDTH=1280" -generic_top "HEIGHT=720""
)
if not exist "%SIM_OUT%" mkdir "%SIM_OUT%"
cd "%SIM_OUT%"
>result.txt echo RUNNING
call "%SIM_BIN%\xvlog.bat" -sv "../../user_source/hdl_source/video_mode_control.v" "../../user_source/hdl_source/isp/rgb_edge_switch_96.v" "../../user_source/hdl_source/isp/edge_detect_96.v" "../../user_source/hdl_source/isp/data96_128/data96_128.v" "../tb_video_mode_control.sv" "../tb_rgb_edge_switch.sv" -log xvlog.log >compile_console.log 2>&1
if errorlevel 1 goto failed
call "%SIM_BIN%\xelab.bat" -timescale 1ns/1ps work.tb_video_mode_control -s mode_button_sim -log button_elab.log >button_elab_console.log 2>&1
if errorlevel 1 goto failed
call "%SIM_BIN%\xsim.bat" mode_button_sim -runall -log button_sim.log >button_console.log 2>&1
if errorlevel 1 goto failed
findstr /c:"VIDEO_MODE_BUTTON_TEST_PASS" button_console.log >nul
if errorlevel 1 goto failed
call :video_test 1
if errorlevel 1 goto failed
call :video_test 0
if errorlevel 1 goto failed
>result.txt echo PASS
type result.txt
type button_console.log
findstr /c:"FRAME_PASS" /c:"RGB_EDGE_SWITCH_TEST_PASS" video_1_console.log video_0_console.log
popd
if /I not "%~1"=="--no-pause" pause
exit /b 0
:video_test
call "%SIM_BIN%\xelab.bat" -timescale 1ns/1ps %SIZE_PARAMS% -generic_top "DEFAULT_EDGE=%~1" work.tb_rgb_edge_switch -s video_mode_%~1 -log video_%~1_elab.log >video_%~1_elab_console.log 2>&1
if errorlevel 1 exit /b 1
call "%SIM_BIN%\xsim.bat" video_mode_%~1 -runall -log video_%~1_sim.log >video_%~1_console.log 2>&1
if errorlevel 1 exit /b 1
findstr /c:"RGB_EDGE_SWITCH_TEST_PASS" video_%~1_console.log >nul
exit /b %errorlevel%
:failed
>result.txt echo FAIL
echo Video mode simulation FAILED. Read sim\%SIM_OUT% logs.
popd
if /I not "%~1"=="--no-pause" pause
exit /b 1
