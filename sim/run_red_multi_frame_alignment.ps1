param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sources = @(
    'user_source\hdl_source\design_top_wrapper.v',
    'user_source\hdl_source\target_frame_bridge.v',
    'user_source\hdl_source\camera_diag_cdc.v',
    'user_source\hdl_source\cnn\cnn_result_cdc.v',
    'user_source\hdl_source\video_in.v',
    'user_source\hdl_source\video_out.v',
    'user_source\hdl_source\video_latency_monitor.v',
    'user_source\hdl_source\video_latency_timebase.v',
    'user_source\hdl_source\video_latency_osd.v',
    'user_source\hdl_source\hdmi_mixer.v',
    'user_source\hdl_source\gamma_lut_rgb888.v',
    'user_source\hdl_source\display_effects_rgb888.v',
    'user_source\hdl_source\display_effect_control.v',
    'user_source\hdl_source\anlogic_logo_rom.v',
    'user_source\hdl_source\osd_char_lib.v',
    'sim\tb_red_multi_frame_alignment.sv'
)
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_red_multi_frame_alignment_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources = @()
foreach ($relative in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $destination
    $compiledSources += $destination
}
# Reuse only the inert peripheral declarations; the legacy test module is
# deliberately excluded so it cannot instantiate another top-level DUT.
$legacyText = [IO.File]::ReadAllText((Join-Path $projectRoot 'sim\tb_target_frame_alignment.sv'))
$stubMarker = '`ifdef TARGET_ALIGNMENT_STUBS'
$stubStart = $legacyText.IndexOf($stubMarker, [StringComparison]::Ordinal)
if ($stubStart -lt 0) {
    throw 'Shared target-alignment peripheral stubs were not found'
}
$stubFile = Join-Path $simulationDir 'target_alignment_peripheral_stubs.sv'
[IO.File]::WriteAllText($stubFile, $legacyText.Substring($stubStart),
    [Text.UTF8Encoding]::new($false))
$compiledSources += $stubFile
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv -d TARGET_ALIGNMENT_STUBS @compiledSources `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Production multi-frame compile failed: $simulationDir\compile_console.log"
    }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug all `
        work.tb_red_multi_frame_alignment -s red_multi_frame_alignment -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Production multi-frame elaboration failed: $simulationDir\elaborate_console.log"
    }
    & (Join-Path $SimBin 'xsim.bat') red_multi_frame_alignment -runall `
        -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Production multi-frame simulation failed: $simulationDir\simulate_console.log"
    }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
        [regex]::Matches($console, '(?m)^RED_MULTI_FRAME_ALIGNMENT_PASS\b').Count -ne 1) {
        throw "Production multi-frame regression did not pass: $simulationDir\simulate_console.log"
    }
    Select-String -LiteralPath simulate_console.log -Pattern '^RED_MULTI_FRAME_ALIGNMENT_PASS\b' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
