param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [switch] $ProductionLightingOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'user_source\hdl_source'
$wrapper = Get-Content -Raw -LiteralPath (Join-Path $sourceRoot 'design_top_wrapper.v')
$controller = Get-Content -Raw -LiteralPath (Join-Path $sourceRoot 'auto_exposure_control.v')
$isp = Get-Content -Raw -LiteralPath (Join-Path $sourceRoot 'isp\isp_top.v')
$productionBlock = [regex]::Match($wrapper,
    '(?s)auto_exposure_control\s*#\((.*?)\)\s*u_auto_exposure')
if (-not $productionBlock.Success) {
    throw 'Production auto_exposure_control instance was not found.'
}
$productionValues = [ordered]@{}
foreach ($name in @('TARGET_LOW', 'TARGET_HIGH', 'DARK_FAST', 'BRIGHT_FAST',
                    'GAIN_MAX', 'SETTLE_FRAMES', 'AVERAGE_FRAMES', 'FAST_AVERAGE_FRAMES', 'METER_MAX',
                    'EXPOSURE_MIN', 'EXPOSURE_MAX', 'EXPOSURE_DEFAULT',
                    'GAIN_MIN', 'GAIN_DEFAULT', 'HIGHLIGHT_ENABLE',
                    'FIXED_SAMPLE_COUNT', 'CHECK_BRIGHT_COUNT')) {
    $setting = [regex]::Match($productionBlock.Groups[1].Value,
        '\.' + $name + '\s*\(\s*(\d+)\s*\)')
    if (-not $setting.Success) {
        $setting = [regex]::Match($controller,
            'parameter\s+integer\s+' + $name + '\s*=\s*(\d+)')
    }
    if (-not $setting.Success) { throw "Cannot read production AE $name" }
    $productionValues[$name] = [int]$setting.Groups[1].Value
}
# Scene illumination and register decoding use these fixed SC520 ranges.
# Reject a future production override instead of silently testing defaults.
$modeledBounds = @{
    EXPOSURE_MIN = 4; EXPOSURE_MAX = 1991; EXPOSURE_DEFAULT = 1000
    GAIN_MIN = 16; GAIN_DEFAULT = 16
}
foreach ($name in @($modeledBounds.Keys)) {
    if ($productionValues[$name] -ne $modeledBounds[$name]) {
        throw "Production AE $name is outside this lighting model; update its scenes before acceptance."
    }
}
$meterBlock = [regex]::Match($isp,
    '(?s)ae_frame_stats_raw10_4x\s*#\((.*?)\)\s*u_ae_frame_stats')
$meterCap = [regex]::Match($meterBlock.Groups[1].Value,
    '\.CLIP_LEVEL\s*\(\s*(\d+)\s*\)')
if (-not $meterBlock.Success -or -not $meterCap.Success -or
    [int]$meterCap.Groups[1].Value -ne $productionValues['METER_MAX']) {
    throw 'Production RAW metering cap and AE meter maximum must agree.'
}
$meterSource = Get-Content -Raw -LiteralPath (Join-Path $sourceRoot 'isp\ae_frame_stats_raw10_4x.v')
foreach ($name in @('HISTOGRAM_ENABLE','HIST_BIN_BITS','BRIGHT_LEVEL','HOLD_OUTPUTS')) {
    $setting=[regex]::Match($meterBlock.Groups[1].Value,
        '\.'+$name+'\s*\(\s*(\d+)\s*\)')
    if(-not $setting.Success) {
        $setting=[regex]::Match($meterSource,'parameter\s+integer\s+'+$name+'\s*=\s*(\d+)')
    }
    if(-not $setting.Success) { throw "Cannot read production RAW $name" }
    $productionValues[$name]=[int]$setting.Groups[1].Value
}
# The reduced lighting scene preserves the sample-count contract, not the
# production frame geometry. Check the real meter contract before scaling it.
if ($productionValues['FIXED_SAMPLE_COUNT'] -ne 0 -and
    $productionValues['FIXED_SAMPLE_COUNT'] -ne 28800) {
    throw 'Update the reduced lighting model for the production fixed sample count.'
}
$lightingGenerics = @()
foreach ($name in @('TARGET_LOW', 'TARGET_HIGH', 'DARK_FAST', 'BRIGHT_FAST',
                    'GAIN_MAX', 'SETTLE_FRAMES', 'AVERAGE_FRAMES', 'FAST_AVERAGE_FRAMES', 'METER_MAX',
                    'HIGHLIGHT_ENABLE', 'HISTOGRAM_ENABLE', 'HIST_BIN_BITS',
                    'BRIGHT_LEVEL', 'FIXED_SAMPLE_COUNT', 'CHECK_BRIGHT_COUNT',
                    'HOLD_OUTPUTS')) {
    $genericName = if ($name -eq 'METER_MAX') { 'METER_CAP' } else { $name }
    $lightingGenerics += @('-generic_top',
        ('"' + $genericName + '=' + $productionValues[$name] + '"'))
}
$lightingTest = @{
    Top = 'tb_ae_lighting_loop'; Snapshot = 'ae_production_lighting'; Pass = '^AE_LIGHTING_LOOP_PASS';
    Generics = $lightingGenerics
}
$tests = @($lightingTest)
if (-not $ProductionLightingOnly) {
    $tests = @(
        @{ Top = 'tb_auto_exposure_control'; Snapshot = 'ae_control'; Pass = '^AUTO_EXPOSURE_CONTROL_PASS' },
        @{ Top = 'tb_ae_short_exposure'; Snapshot = 'ae_short_exposure'; Pass = '^AE_SHORT_EXPOSURE_PASS' },
        @{ Top = 'tb_ae_accumulator_bounds'; Snapshot = 'ae_accumulator_bounds'; Pass = '^AE_ACCUMULATOR_BOUNDS_PASS' },
        @{ Top = 'tb_ae_frame_stats_raw10_4x'; Snapshot = 'ae_raw_stats'; Pass = '^AE_FRAME_STATS_RAW10_PASS' },
        @{ Top = 'tb_ae_stats_cdc'; Snapshot = 'ae_cdc'; Pass = '^AE_STATS_CDC_PASS' },
        @{ Top = 'tb_ae_highlight_control'; Snapshot = 'ae_highlight'; Pass = '^AE_HIGHLIGHT_CONTROL_PASS' },
        @{ Top = 'tb_ae_fixed_count'; Snapshot = 'ae_fixed_count'; Pass = '^AE_FIXED_COUNT_PASS' },
        @{ Top = 'tb_ae_fast_window'; Snapshot = 'ae_fast_window'; Pass = '^AE_FAST_WINDOW_PASS' },
        $lightingTest
    )
    $tests += @{
        Top='tb_ae_lighting_loop'; Snapshot='ae_mean_only_lighting'; Pass='^AE_LIGHTING_LOOP_PASS'
        Generics=@('-generic_top','"HIGHLIGHT_ENABLE=0"','-generic_top','"HISTOGRAM_ENABLE=0"')
    }
}
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
    (Join-Path $sourceRoot 'isp\ae_frame_stats_raw10_4x.v'),
    (Join-Path $sourceRoot 'uics520_cfg\SC520GainTbl.v'),
    (Join-Path $sourceRoot 'uics520_cfg\uics520regAE.v'),
    (Join-Path $PSScriptRoot 'tb_auto_exposure_control.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_short_exposure.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_accumulator_bounds.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_frame_stats_raw10_4x.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_stats_cdc.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_highlight_control.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_fixed_count.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_fast_window.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_lighting_loop.sv')
)
$snapshotDirectory = Join-Path $simulationDir 'sources'
New-Item -ItemType Directory -Path $snapshotDirectory | Out-Null
$compiledSources = @()
$sourceHashes = foreach ($source in $sources) {
    $snapshot = Join-Path $snapshotDirectory (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $snapshot
    $compiledSources += $snapshot
    [pscustomobject]@{
        Path = $source.Substring($projectRoot.Length + 1).Replace('\', '/')
        SHA256 = (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
    }
}
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$productionValues.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{Parameter = $_.Key; Value = $_.Value}
} | Export-Csv -LiteralPath (Join-Path $simulationDir 'production_parameters.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
Write-Output ('Production AE: ' + (($productionValues.GetEnumerator() |
    ForEach-Object { $_.Key + '=' + $_.Value }) -join ' '))
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @compiledSources -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim compile failed; see compile_console.log' }
    foreach ($test in $tests) {
        $elaborateLog = $test.Snapshot + '_elaborate_console.log'
        $simulationLog = $test.Snapshot + '_simulate_console.log'
        $generics = @()
        if ($test.ContainsKey('Generics')) { $generics = $test.Generics }
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            ('work.' + $test.Top) @generics -s $test.Snapshot -log ($test.Snapshot + '_xelab.log') *> $elaborateLog
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
