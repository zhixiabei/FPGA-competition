@echo off
setlocal
set "SIM_BIN=D:\XILINX\Vivado\2021.1\bin"
if defined VIVADO_SIM_BIN set "SIM_BIN=%VIVADO_SIM_BIN%"
pushd "%~dp0"
if not exist out_sc520 mkdir out_sc520
cd out_sc520
>result.txt echo RUNNING
call "%SIM_BIN%\xvlog.bat" -sv "../tb_sc520_config.sv" "../../user_source/hdl_source/uics520_cfg/uicfgcs520.v" "../../user_source/hdl_source/uics520_cfg/uics520reg_720p60.v" "../../user_source/hdl_source/uics520_cfg/uics520regAE.v" "../../user_source/hdl_source/uics520_cfg/SC520GainTbl.v" "../../user_source/hdl_source/uics500_cfg/uii2c.v" -log xvlog.log >compile_console.log 2>&1
if errorlevel 1 goto failed
call "%SIM_BIN%\xelab.bat" -timescale 1ns/1ps -debug typical work.tb_sc520_config -s sc520_config_sim -log xelab.log >elaborate_console.log 2>&1
if errorlevel 1 goto failed
call "%SIM_BIN%\xsim.bat" sc520_config_sim -runall -log xsim.log >simulate_console.log 2>&1
if errorlevel 1 goto failed
findstr /c:"SC520_CONFIG_TEST_PASS" simulate_console.log >nul
if errorlevel 1 goto failed
>result.txt echo PASS
type simulate_console.log
popd
if /I not "%~1"=="--no-pause" pause
exit /b 0
:failed
>result.txt echo FAIL
echo SC520 simulation failed. Read sim\out_sc520 logs.
popd
if /I not "%~1"=="--no-pause" pause
exit /b 1
