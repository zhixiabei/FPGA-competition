param(
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sources = @(
    'user_source\hdl_source\isp\isp_top.v',
    'user_source\hdl_source\isp\lsc_raw10_4x.v',
    'user_source\hdl_source\awb.v',
    'user_source\hdl_source\isp\ae_frame_stats_raw10_4x.v',
    'user_source\hdl_source\isp\rgb_edge_switch_96.v',
    'user_source\hdl_source\isp\scharr_edge_detect_96.v',
    'user_source\hdl_source\isp\red_target_detect_96.v',
    'user_source\hdl_source\isp\motion_target_detect_96.v',
    'user_source\hdl_source\isp\target_detect_switch_96.v',
    'user_source\hdl_source\isp\data96_128\data96_128.v',
    'user_source\hdl_source\isp\data128_96\data128_96.v',
    'user_source\hdl_source\isp\demosaic_4x_2_0\demosaic.v',
    'user_source\hdl_source\isp\demosaic_4x_2_0\raw_matrix_3x3_buffer.v',
    'user_source\hdl_source\isp\demosaic_4x_2_0\bilinear_interpolation.v',
    'sim\tb_video_latency_frame_tag.sv'
)
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_video_latency_frame_tag_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources = @()
foreach ($relative in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $destination
    $compiledSources += $destination
}
foreach ($primitive in @('ph1p_logic_eram.v', 'ph1p_phy_gsr.v')) {
    $destination = Join-Path $simulationDir $primitive
    Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $destination
    $compiledSources += $destination
}
$primitiveText = [IO.File]::ReadAllText((Join-Path $TdSimLib 'ph1p_logic_dram.v'))
$primitiveModule = [regex]::Match($primitiveText, '(?s)\A.*?\bendmodule\b')
if (-not $primitiveModule.Success -or
    -not $primitiveModule.Value.Contains('module PH1P_LOGIC_DRAM')) {
    throw 'TD distributed RAM functional model was not found'
}
$primitiveSource = Join-Path $simulationDir 'ph1p_logic_dram.v'
[IO.File]::WriteAllText($primitiveSource,
    $primitiveModule.Value + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$compiledSources += $primitiveSource
$hashes = foreach ($source in $compiledSources) {
    [pscustomobject]@{
        File = Split-Path -Leaf $source
        SHA256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$tclSources = ($compiledSources | ForEach-Object { '{' + $_.Replace('\', '/') + '}' }) -join ' '
$runScript = @"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv $tclSources
vsim -t ps work.tb_video_latency_frame_tag work.PH1P_PHY_GSR
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript, [Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Frame-tag simulation failed: $simulationDir\console.log"
    }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
        [regex]::Matches($console,
            '(?m)^\s*(?:#\s*)?VIDEO_LATENCY_FRAME_TAG_PASS\b').Count -ne 1) {
        throw "Frame-tag regression did not pass: $simulationDir\console.log"
    }
    Select-String -LiteralPath console.log -Pattern 'VIDEO_LATENCY_FRAME_TAG_PASS' |
        ForEach-Object { $_.Line -replace '^#\s*', '' }
} finally {
    Pop-Location
}
