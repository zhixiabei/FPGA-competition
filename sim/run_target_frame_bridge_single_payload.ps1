param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}

$simulationDir = Join-Path $env:TEMP ('anlogic_bridge_single_payload_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    (Join-Path $PSScriptRoot 'reference\ph1p_logic_dram_asym_sim.v'),
    (Join-Path $projectRoot 'user_source\hdl_source\target_frame_bridge.v'),
    (Join-Path $PSScriptRoot 'tb_target_frame_bridge_single_payload.sv')
)
$compiledSources = @()
foreach ($source in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $destination
    $compiledSources += $destination
}
Write-Output "Simulation output: $simulationDir"

Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @compiledSources `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Single-target bridge compile failed: $simulationDir\compile_console.log"
    }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug all `
        work.tb_target_frame_bridge_single_payload -s bridge_single_payload `
        -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Single-target bridge elaboration failed: $simulationDir\elaborate_console.log"
    }
    & (Join-Path $SimBin 'xsim.bat') bridge_single_payload -runall `
        -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Single-target bridge simulation failed: $simulationDir\simulate_console.log"
    }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
        [regex]::Matches($console, '(?m)^TARGET_FRAME_BRIDGE_SINGLE_PAYLOAD_PASS\b').Count -ne 1) {
        throw "Single-target bridge verification did not pass: $simulationDir\simulate_console.log"
    }
    Select-String -LiteralPath simulate_console.log `
        -Pattern '^TARGET_FRAME_BRIDGE_SINGLE_PAYLOAD_PASS\b' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
