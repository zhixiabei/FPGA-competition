param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sources = @(
    'user_source\hdl_source\target_frame_bridge.v',
    'sim\tb_target_frame_bridge.sv'
)
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_target_frame_bridge_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources = @()
foreach ($relative in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $destination
    $compiledSources += $destination
}
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @compiledSources `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Frame bridge compile failed: $simulationDir\compile_console.log"
    }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug all `
        work.tb_target_frame_bridge -s target_frame_bridge -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Frame bridge elaboration failed: $simulationDir\elaborate_console.log"
    }
    & (Join-Path $SimBin 'xsim.bat') target_frame_bridge -runall `
        -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Frame bridge simulation failed: $simulationDir\simulate_console.log"
    }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
        [regex]::Matches($console, '(?m)^TARGET_FRAME_BRIDGE_PASS\b').Count -ne 1) {
        throw "Frame bridge regression did not pass: $simulationDir\simulate_console.log"
    }
    Select-String -LiteralPath simulate_console.log -Pattern '^TARGET_FRAME_BRIDGE_PASS\b' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
