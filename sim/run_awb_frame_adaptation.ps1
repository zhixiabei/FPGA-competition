param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_awb_frame_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'user_source\hdl_source\awb.v') `
    -Destination (Join-Path $simulationDir 'awb.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_awb_frame_adaptation.sv') `
    -Destination (Join-Path $simulationDir 'tb_awb_frame_adaptation.sv')
# Use the actual vendor functional DRAM module, without the following
# encrypted PHY modules that XSim cannot read. Do not substitute a RAM stub.
$primitiveText = [System.IO.File]::ReadAllText((Join-Path $TdSimLib 'ph1p_logic_dram.v'))
$primitiveModule = [regex]::Match($primitiveText, '(?s)\A.*?\bendmodule\b')
if (-not $primitiveModule.Success -or
    -not $primitiveModule.Value.Contains('module PH1P_LOGIC_DRAM')) {
    throw 'TD distributed RAM functional model was not found'
}
[System.IO.File]::WriteAllText((Join-Path $simulationDir 'ph1p_logic_dram.v'),
    $primitiveModule.Value + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv ph1p_logic_dram.v awb.v tb_awb_frame_adaptation.sv `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'AWB compile failed; see compile_console.log' }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        work.tb_awb_frame_adaptation -s awb_frame_adaptation -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'AWB elaboration failed; see elaborate_console.log' }
    & (Join-Path $SimBin 'xsim.bat') awb_frame_adaptation -runall `
        -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'AWB simulation failed; see simulate_console.log' }
    $pass = Select-String -LiteralPath simulate_console.log -Pattern '^AWB_FRAME_ADAPTATION_PASS'
    if (-not $pass) { throw 'AWB regression did not pass; see simulate_console.log' }
    $pass.Line
} finally {
    Pop-Location
}
