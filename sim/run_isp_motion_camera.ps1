param(
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p',
    [string] $AwbSource = '',
    [switch] $ExpectBrokenLast,
    [ValidateRange(8, 3000)]
    [int] $LineBlanking = 32,
    [ValidateRange(1, 128)]
    [int] $MovePixels = 4
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
    'sim\tb_isp_motion_camera.sv'
)
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_isp_motion_camera_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources = @()
$awbSourcePath = ''
foreach ($relative in $sources) {
    $source = Join-Path $projectRoot $relative
    if ($AwbSource -and $relative -eq 'user_source\hdl_source\awb.v') {
        $source = $AwbSource
    }
    if ($relative -eq 'user_source\hdl_source\awb.v') {
        $awbSourcePath = (Get-Item -LiteralPath $source).FullName
    }
    $destination = Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath $source -Destination $destination
    $compiledSources += $destination
}
foreach ($primitive in @('ph1p_logic_eram.v', 'ph1p_phy_gsr.v')) {
    $destination = Join-Path $simulationDir $primitive
    Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $destination
    $compiledSources += $destination
}
# Extract the unchanged plaintext functional model ahead of encrypted variants.
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
$tclSources = ($compiledSources | ForEach-Object { '{' + $_.Replace('\', '/') + '}' }) -join ' '
$broken = [int] $ExpectBrokenLast.IsPresent
$awbHash = (Get-FileHash -LiteralPath (Join-Path $simulationDir 'awb.v') -Algorithm SHA256).Hash
$runScript = @"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv $tclSources
vsim -t ps -gEXPECT_BROKEN_LAST=$broken -gLINE_BLANKING=$LineBlanking -gMOVE_PIXELS=$MovePixels work.tb_isp_motion_camera work.PH1P_PHY_GSR
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript, [Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Write-Output "Simulation configuration: frames=6 expect_broken_last=$broken line_blanking=$LineBlanking move_pixels=$MovePixels threshold=10 min_blocks=12 stable=1 target_latency=13"
Write-Output "AWB source: $awbSourcePath"
Write-Output "AWB snapshot SHA256: $awbHash"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if ($LASTEXITCODE -ne 0) {
        throw "ISP camera motion simulation failed: $simulationDir\console.log"
    }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    $passPattern = if ($ExpectBrokenLast) {
        'ISP_MOTION_CAMERA_BASELINE_PASS'
    } else {
        'ISP_MOTION_CAMERA_PASS'
    }
    if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
        $console -notmatch "(?m)^\s*(?:#\s*)?$passPattern\b") {
        throw "ISP camera motion regression did not pass: $simulationDir\console.log"
    }
    Select-String -LiteralPath console.log -Pattern 'ISP_MOTION_CAMERA_(FRAME|BASELINE_PASS|PASS)' |
        ForEach-Object { $_.Line -replace '^#\s*', '' }
} finally {
    Pop-Location
}
