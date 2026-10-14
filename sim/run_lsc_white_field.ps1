param([string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
      [string] $TdSimLib='D:\TD\sim_release\ph1p')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $env:TEMP ('anlogic_lsc_white_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
& python (Join-Path $root 'verification/check_lsc_calibration.py') --sim-dir $work --white-fixtures
if($LASTEXITCODE -ne 0) { throw 'White field fixture generation failed' }
$sources=@('isp/lsc_raw10_4x.v','isp/ae_frame_stats_96.v','awb.v','isp/data128_96/data128_96.v',
 'isp/demosaic_4x_2_0/demosaic.v','isp/demosaic_4x_2_0/raw_matrix_3x3_buffer.v',
 'isp/demosaic_4x_2_0/bilinear_interpolation.v')
foreach($relative in $sources) {
    Copy-Item -LiteralPath (Join-Path $root "user_source/hdl_source/$relative") -Destination $work
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_lsc_white_field.sv') -Destination $work
foreach($name in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')) {
    Copy-Item -LiteralPath (Join-Path $TdSimLib $name) -Destination $work
}
$dram=[regex]::Match([IO.File]::ReadAllText((Join-Path $TdSimLib 'ph1p_logic_dram.v')), '(?s)\A.*?\bendmodule\b').Value
[IO.File]::WriteAllText((Join-Path $work 'ph1p_logic_dram.v'),$dram,[Text.UTF8Encoding]::new($false))
$script=@'
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv lsc_raw10_4x.v ae_frame_stats_96.v awb.v data128_96.v demosaic.v raw_matrix_3x3_buffer.v bilinear_interpolation.v ph1p_logic_eram.v ph1p_phy_gsr.v ph1p_logic_dram.v tb_lsc_white_field.sv
vsim -t ps work.tb_lsc_white_field work.PH1P_PHY_GSR
run -all
quit -code 0 -force
'@
[IO.File]::WriteAllText((Join-Path $work 'run.do'),$script,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $work"
Push-Location $work
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if($LASTEXITCODE -ne 0) { throw "White field simulation failed: $work/console.log" }
    $log=[IO.File]::ReadAllText((Join-Path $work 'console.log'))
    if($log -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
       $log -notmatch 'LSC_WHITE_FIELD_PASS' -or $log -notmatch 'LSC_METER_REPRO_PASS') {
        throw "White field regression incomplete: $work/console.log"
    }
    Select-String -LiteralPath console.log -Pattern 'WHITE_ROI|LSC_WHITE_FIELD_PASS|LSC_METER_' | ForEach-Object { $_.Line }
} finally { Pop-Location }
