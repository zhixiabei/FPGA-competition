param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [int] $Width = 64,
    [int] $Height = 48
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $projectRoot 'user_source\hdl_source\isp\red_target_detect_96.v'
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}

$simulationDir = Join-Path $env:TEMP ('anlogic_red_lighting_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $simulationDir 'red_target_detect_96.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_red_target_detect_96.sv') `
    -Destination (Join-Path $simulationDir 'tb_red_target_detect_96.sv')
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv red_target_detect_96.v tb_red_target_detect_96.sv `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim compile failed; see compile_console.log' }

    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        -generic_top ('"W=' + $Width + '"') -generic_top ('"H=' + $Height + '"') `
        work.tb_red_target_detect_96 -s red_target_lighting -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim elaboration failed; see elaborate_console.log' }

    & (Join-Path $SimBin 'xsim.bat') red_target_lighting -runall -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim simulation failed; see simulate_console.log' }
    $pass = Select-String -LiteralPath simulate_console.log -Pattern '^RED_TARGET_LIGHTING_PASS'
    if (-not $pass) { throw 'Red target lighting test did not pass; see simulate_console.log' }
    $pass.Line
} finally {
    Pop-Location
}
