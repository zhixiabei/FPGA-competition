param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'user_source\hdl_source'
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_auto_exposure_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    (Join-Path $sourceRoot 'auto_exposure_control.v'),
    (Join-Path $sourceRoot 'ae_stats_cdc.v'),
    (Join-Path $sourceRoot 'isp\ae_frame_stats_96.v'),
    (Join-Path $sourceRoot 'uics520_cfg\SC520GainTbl.v'),
    (Join-Path $sourceRoot 'uics520_cfg\uics520regAE.v'),
    (Join-Path $PSScriptRoot 'tb_auto_exposure_control.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_frame_stats_96.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_stats_cdc.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_lighting_loop.sv')
)
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @sources -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim compile failed; see compile_console.log' }
    foreach ($test in @(
        @{ Top = 'tb_auto_exposure_control'; Snapshot = 'ae_control'; Pass = '^AUTO_EXPOSURE_CONTROL_PASS' },
        @{ Top = 'tb_ae_frame_stats_96'; Snapshot = 'ae_stats'; Pass = '^AE_FRAME_STATS_PASS' },
        @{ Top = 'tb_ae_stats_cdc'; Snapshot = 'ae_cdc'; Pass = '^AE_STATS_CDC_PASS' },
        @{ Top = 'tb_ae_lighting_loop'; Snapshot = 'ae_lighting_loop'; Pass = '^AE_LIGHTING_LOOP_PASS' }
    )) {
        $elaborateLog = $test.Snapshot + '_elaborate_console.log'
        $simulationLog = $test.Snapshot + '_simulate_console.log'
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            ('work.' + $test.Top) -s $test.Snapshot -log ($test.Snapshot + '_xelab.log') *> $elaborateLog
        if ($LASTEXITCODE -ne 0) { throw "XSim elaboration failed; see $elaborateLog" }
        & (Join-Path $SimBin 'xsim.bat') $test.Snapshot -runall `
            -log ($test.Snapshot + '_xsim.log') *> $simulationLog
        if ($LASTEXITCODE -ne 0) { throw "XSim simulation failed; see $simulationLog" }
        $pass = Select-String -LiteralPath $simulationLog -Pattern $test.Pass
        if (-not $pass) { throw "Test did not pass; see $simulationLog" }
        $pass.Line
    }
} finally {
    Pop-Location
}
