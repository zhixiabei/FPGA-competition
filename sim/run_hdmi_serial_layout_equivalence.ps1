param(
    [string] $ReferenceRtl='',
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [switch] $CandidateSweep,
    [switch] $PixelProbes
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
if(-not $ReferenceRtl) {
    $ReferenceRtl=Join-Path $projectRoot 'build/shape_display_compression/baseline_20261027/user_source/hdl_source/hdmi_mixer.v'
}
$simulationDir=Join-Path $env:TEMP ('anlogic_serial_layout_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources=@('hdmi_mixer.v','display_effects_rgb888.v','gamma_lut_rgb888.v',
    'anlogic_logo_rom.v','osd_char_lib.v','video_latency_osd.v','raw_stats_osd.v')
foreach($source in $sources) {
    Copy-Item -LiteralPath (Join-Path $projectRoot ('user_source/hdl_source/'+$source)) `
        -Destination (Join-Path $simulationDir $source)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_hdmi_serial_layout_equivalence.sv') `
    -Destination $simulationDir
$referenceText=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $ReferenceRtl))
$referenceText=[regex]::Replace($referenceText,'\bhdmi_mixer\b','hdmi_mixer_reference')
[IO.File]::WriteAllText((Join-Path $simulationDir 'hdmi_mixer_reference.v'),
    $referenceText,[Text.UTF8Encoding]::new($false))
$sourceFiles=@(Get-ChildItem -LiteralPath $simulationDir -File)
$sourceFiles |
    Get-FileHash -Algorithm SHA256 |
    Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$compile=@($sources+'hdmi_mixer_reference.v'+'tb_hdmi_serial_layout_equivalence.sv') -join ' '
$pixelProbeValue=if($PixelProbes) {1} else {0}
$candidateRun=if($CandidateSweep) {@"
vsim -t ps work.tb_hdmi_serial_layout_equivalence -gW=1280 -gH=720 -gCASES=4096 -gSWEEP=1
onfinish stop
run -all
quit -sim
"@} else {''}
$runScript=@"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $compile
vsim -t ps work.tb_hdmi_serial_layout_equivalence -gW=1280 -gH=720 -gCASES=192 -gPIXEL_PROBES=$pixelProbeValue
onfinish stop
run -all
quit -sim
vsim -t ps work.tb_hdmi_serial_layout_equivalence -gW=640 -gH=360 -gCASES=192 -gPIXEL_PROBES=$pixelProbeValue
onfinish stop
run -all
quit -sim
vsim -t ps work.tb_hdmi_serial_layout_equivalence -gW=128 -gH=80 -gCASES=48 -gPIXEL_PROBES=$pixelProbeValue
onfinish stop
run -all
quit -sim
vsim -t ps work.tb_hdmi_serial_layout_equivalence -gW=64 -gH=64 -gCASES=48 -gPIXEL_PROBES=$pixelProbeValue
onfinish stop
run -all
quit -sim
$candidateRun
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if($LASTEXITCODE -ne 0) {
        throw "Serial layout simulation failed: $simulationDir/console.log"
    }
    $console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    $passes=[regex]::Matches($console,'(?m)^\s*(?:#\s*)?HDMI_SERIAL_LAYOUT_EQUIVALENCE_PASS\b.*$')
    $expectedPasses=if($CandidateSweep) {5} else {4}
    if($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or $passes.Count -ne $expectedPasses) {
        throw "Serial layout verification did not pass all four sizes: $simulationDir/console.log"
    }
    $passes | ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
} finally {
    Pop-Location
}
