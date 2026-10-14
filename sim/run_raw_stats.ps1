param([string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem', [switch] $HdmiOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $env:TEMP ('anlogic_raw_stats_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$sources=@('user_source/hdl_source/isp/raw_region_stats.v',
    'user_source/hdl_source/raw_stats_osd.v','user_source/hdl_source/ae_stats_cdc.v',
    'user_source/hdl_source/hdmi_mixer.v','user_source/hdl_source/osd_char_lib.v',
    'sim/tb_raw_region_stats.sv','sim/tb_raw_stats_hdmi.sv')
foreach($relative in $sources) { Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $work }
$script=@'
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv raw_region_stats.v raw_stats_osd.v ae_stats_cdc.v hdmi_mixer.v osd_char_lib.v tb_raw_region_stats.sv tb_raw_stats_hdmi.sv
foreach geometry {RAW_GEOMETRIES} {
    lassign $geometry width height patch
    vsim -t ps -gW=$width -gH=$height -gL=$patch work.tb_raw_region_stats
    onfinish stop
    run -all
    quit -sim
}
vsim -t ps work.tb_raw_stats_hdmi
onfinish stop
run -all
quit -sim
quit -code 0 -force
'@
$geometries=if($HdmiOnly) { '' } else { '{64 48 3} {1280 720 5}' }
$script=$script.Replace('RAW_GEOMETRIES',$geometries)
[IO.File]::WriteAllText((Join-Path $work 'run.do'),$script,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $work"
Push-Location $work
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if($LASTEXITCODE -ne 0) { throw "Statistics simulation failed: $work\console.log" }
    $log=[IO.File]::ReadAllText((Join-Path $work 'console.log'))
    if($log -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
        (-not $HdmiOnly -and [regex]::Matches($log,'RAW_REGION_STATS_PASS mode=').Count -ne 8) -or
        $log -notmatch 'RAW_STATS_HDMI_PASS') {
        throw "Incomplete or failed statistics regression: $work\console.log"
    }
    Select-String -LiteralPath console.log -Pattern 'RAW_REGION_STATS_PASS|RAW_STATS_HDMI_PASS' | ForEach-Object { $_.Line }
} finally { Pop-Location }
