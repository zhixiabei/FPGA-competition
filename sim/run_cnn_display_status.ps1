param(
    [string] $VivadoBin = 'D:\Xilinx\Vivado\2021.1\bin'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sources = @(
    'user_source\hdl_source\display_effects_rgb888.v',
    'user_source\hdl_source\gamma_lut_rgb888.v',
    'user_source\hdl_source\hdmi_mixer.v',
    'user_source\hdl_source\anlogic_logo_rom.v',
    'user_source\hdl_source\osd_char_lib.v',
    'sim\tb_cnn_display_status.sv'
)
$simulationDir = Join-Path $env:TEMP ('anlogic_cnn_display_status_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
[string[]] $sourcePaths = foreach ($relative in $sources) {
    $source = Join-Path $projectRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing simulation source: $source"
    }
    $source.Replace('\', '/')
}
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $VivadoBin 'xvlog.bat') -sv @sourcePaths -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) {
        Get-Content compile_console.log -Tail 40
        throw 'CNN display status compilation failed'
    }
    & (Join-Path $VivadoBin 'xelab.bat') -timescale 1ns/1ps `
        work.tb_cnn_display_status -s cnn_display_status -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) {
        Get-Content elaborate_console.log -Tail 40
        throw 'CNN display status elaboration failed'
    }
    & (Join-Path $VivadoBin 'xsim.bat') cnn_display_status -runall -log xsim.log *> simulate_console.log
    $simulationExit = $LASTEXITCODE
    $console = Get-Content simulate_console.log -Raw
    Get-Content simulate_console.log -Tail 20
    if ($simulationExit -ne 0 -or $console -match '(?im)^Fatal:' -or
        $console -notmatch 'CNN_DISPLAY_STATUS_PASS') {
        throw 'CNN display status regression failed'
    }
} finally {
    Pop-Location
}
