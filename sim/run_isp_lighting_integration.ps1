param([string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'user_source\hdl_source'
$sources = @('isp\isp_top.v','awb.v','isp\ae_frame_stats_96.v',
    'isp\rgb_edge_switch_96.v','isp\scharr_edge_detect_96.v',
    'isp\red_target_detect_96.v','isp\data96_128\data96_128.v',
    'isp\data128_96\data128_96.v')
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_isp_lighting_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources=@()
foreach($relative in $sources) {
    $destination=Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination
    $compiledSources+=$destination
}
$testbench=Join-Path $simulationDir 'tb_isp_lighting_integration.sv'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_isp_lighting_integration.sv') -Destination $testbench
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv -d SCHARR_PORTABLE_RAM @compiledSources $testbench `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'ISP integration compile failed; see compile_console.log' }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        work.tb_isp_lighting_integration -s isp_lighting -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'ISP integration elaboration failed; see elaborate_console.log' }
    & (Join-Path $SimBin 'xsim.bat') isp_lighting -runall -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'ISP integration simulation failed; see simulate_console.log' }
    $pass=Select-String -LiteralPath simulate_console.log -Pattern '^ISP_LIGHTING_INTEGRATION_PASS'
    if (-not $pass) { throw 'ISP integration did not pass; see simulate_console.log' }
    $pass.Line
} finally {
    Pop-Location
}
