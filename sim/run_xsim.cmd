@echo off
setlocal
set "SIM_BIN=D:\XILINX\Vivado\2021.1\bin"
if defined VIVADO_SIM_BIN set "SIM_BIN=%VIVADO_SIM_BIN%"
if not exist "%SIM_BIN%\xvlog.bat" (
    echo XSim not found. Edit SIM_BIN in this file or set VIVADO_SIM_BIN.
    if /I not "%~1"=="--no-pause" pause
    exit /b 1
)
pushd "%~dp0"
set "SIM_OUT=out"
set "SIM_PARAMS="
if /I "%~2"=="720" (
    set "SIM_OUT=out_720p"
    set "SIM_PARAMS=-generic_top "WIDTH=1280" -generic_top "HEIGHT=720""
)
if not exist "%SIM_OUT%" mkdir "%SIM_OUT%"
cd "%SIM_OUT%"
>result.txt echo RUNNING
echo [1/3] Compile original edge RTL and testbench...
call "%SIM_BIN%\xvlog.bat" -sv "../../user_source/hdl_source/isp/edge_detect_96.v" "../tb_edge_detect.sv" -log xvlog.log >compile_console.log 2>&1
if errorlevel 1 goto failed
findstr /c:"ERROR:" compile_console.log >nul
if not errorlevel 1 goto failed
echo [2/3] Elaborate...
call "%SIM_BIN%\xelab.bat" -timescale 1ns/1ps -debug typical %SIM_PARAMS% work.tb_edge_detect -s edge_sim -log xelab.log >elaborate_console.log 2>&1
if errorlevel 1 goto failed
findstr /c:"ERROR:" elaborate_console.log >nul
if not errorlevel 1 goto failed
if not exist xsim.dir\edge_sim\xsimk.exe goto failed
echo [3/3] Simulate and compare pixels...
call "%SIM_BIN%\xsim.bat" edge_sim -tclbatch "../run_wave.tcl" -wdb edge.wdb -log xsim.log >simulate_console.log 2>&1
if errorlevel 1 goto failed
findstr /x /c:"PASS" result.txt >nul
if errorlevel 1 goto failed
type result.txt
echo Images: sim\%SIM_OUT%\input.bmp, edge_output.bmp, edge_expected.bmp
echo Waveforms: double-click open_wave.cmd in sim.
popd
if /I not "%~1"=="--no-pause" pause
exit /b 0
:failed
echo Simulation FAILED. Read the logs in sim\%SIM_OUT%.
type result.txt
popd
if /I not "%~1"=="--no-pause" pause
exit /b 1
