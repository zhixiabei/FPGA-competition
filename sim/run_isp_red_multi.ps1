param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'user_source\hdl_source'
$sources = @('isp\isp_top.v', 'isp\lsc_raw10_4x.v', 'awb.v',
    'isp\ae_frame_stats_raw10_4x.v',
    'isp\rgb_edge_switch_96.v', 'isp\scharr_edge_detect_96.v',
    'isp\red_target_detect_96.v', 'isp\motion_target_detect_96.v',
    'isp\target_detect_switch_96.v', 'isp\data96_128\data96_128.v',
    'isp\data128_96\data128_96.v')
if (Test-Path -LiteralPath (Join-Path $sourceRoot 'isp\iq_diagnostic_stats.v')) {
    $sources += 'isp\iq_diagnostic_stats.v'
}
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_isp_red_multi_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources = @()
foreach ($relative in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination
    $compiledSources += $destination
}
$testbench = Join-Path $simulationDir 'tb_isp_red_multi.sv'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_isp_red_multi.sv') -Destination $testbench

# Reuse only the original inert demosaic boundary. All later ISP modules are real.
$originalTb = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tb_isp_lighting_integration.sv'))
$demosaicStub = [regex]::Match($originalTb, '(?ms)^module demosaic #\(.*?^endmodule\s*$')
if (-not $demosaicStub.Success) {
    throw 'The established ISP demosaic test boundary was not found'
}
$stubSource = Join-Path $simulationDir 'demosaic_stub.sv'
[IO.File]::WriteAllText($stubSource, $demosaicStub.Value + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
$compiledSources += $stubSource

# AWB retains the unchanged vendor functional distributed-RAM model.
$primitiveText = [IO.File]::ReadAllText((Join-Path $TdSimLib 'ph1p_logic_dram.v'))
$primitiveModule = [regex]::Match($primitiveText, '(?s)\A.*?\bendmodule\b')
if (-not $primitiveModule.Success -or
    -not $primitiveModule.Value.Contains('module PH1P_LOGIC_DRAM')) {
    throw 'TD distributed RAM functional model was not found'
}
$primitiveSource = Join-Path $simulationDir 'ph1p_logic_dram.v'
[IO.File]::WriteAllText($primitiveSource, $primitiveModule.Value + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
$compiledSources += $primitiveSource
foreach ($primitive in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')) {
    $destination=Join-Path $simulationDir $primitive
    Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $destination
    $compiledSources += $destination
}
$sourceHashes = foreach ($snapshot in @($compiledSources) + @($testbench)) {
    [pscustomobject]@{
        File = (Split-Path -Leaf $snapshot)
        SHA256 = (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
    }
}
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv -d SCHARR_PORTABLE_RAM -d RED_MULTI_PORTABLE_RAM `
        @compiledSources $testbench -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'Production ISP multi-target compile failed; see compile_console.log' }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        work.tb_isp_red_multi -s isp_red_multi -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'Production ISP multi-target elaboration failed; see elaborate_console.log' }
    & (Join-Path $SimBin 'xsim.bat') isp_red_multi -runall -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'Production ISP multi-target simulation failed; see simulate_console.log' }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b') {
        throw 'Production ISP multi-target reported an error; see simulate_console.log'
    }
    $passes = [regex]::Matches($console, '(?m)^ISP_RED_MULTI_PASS\b.*$')
    if ($passes.Count -ne 1) {
        throw 'Production ISP multi-target did not pass exactly once; see simulate_console.log'
    }
    $passes[0].Value.Trim()
} finally {
    Pop-Location
}
