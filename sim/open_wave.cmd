@echo off
setlocal
set "SIM_BIN=D:\XILINX\Vivado\2021.1\bin"
if defined VIVADO_SIM_BIN set "SIM_BIN=%VIVADO_SIM_BIN%"
if not exist "%~dp0out\edge.wdb" (
    echo Run run_xsim.cmd successfully first.
    pause
    exit /b 1
)
pushd "%~dp0out"
call "%SIM_BIN%\vivado.bat" -mode gui -source "../open_wave.tcl"
popd
