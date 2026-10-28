param(
    [string] $ReferenceRtl='',
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
if(-not $ReferenceRtl) {
    $ReferenceRtl=Join-Path $projectRoot 'build/shape_display_compression/variants/display_labels_01/user_source/hdl_source/hdmi_mixer.v'
}
$simulationDir=Join-Path $env:TEMP ('anlogic_shared_font_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources=@('hdmi_mixer.v','display_effects_rgb888.v','gamma_lut_rgb888.v',
    'anlogic_logo_rom.v','osd_char_lib.v','video_latency_osd.v','raw_stats_osd.v')
foreach($source in $sources) {
    Copy-Item -LiteralPath (Join-Path $projectRoot ('user_source/hdl_source/'+$source)) `
        -Destination (Join-Path $simulationDir $source)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_hdmi_shared_font_pixels.sv') `
    -Destination $simulationDir
$referenceText=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $ReferenceRtl))
$referenceText=[regex]::Replace($referenceText,'\bhdmi_mixer\b','hdmi_mixer_reference')
[IO.File]::WriteAllText((Join-Path $simulationDir 'hdmi_mixer_reference.v'),
    $referenceText,[Text.UTF8Encoding]::new($false))
$sourceFiles=@(Get-ChildItem -LiteralPath $simulationDir -File)
$sourceFiles | Get-FileHash -Algorithm SHA256 |
    Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$compile=@($sources+'hdmi_mixer_reference.v'+'tb_hdmi_shared_font_pixels.sv') -join ' '
$runScript=@"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $compile
vsim -t ps work.tb_hdmi_shared_font_pixels -gW=1280 -gH=192 -gMULTI=1 -gFRAMES=13
onfinish stop
run -all
quit -sim
vsim -t ps work.tb_hdmi_shared_font_pixels -gW=640 -gH=160 -gMULTI=0 -gFRAMES=2
onfinish stop
run -all
quit -sim
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if($LASTEXITCODE -ne 0) {
        throw "Shared font simulation failed: $simulationDir/console.log"
    }
    $console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    $passes=[regex]::Matches($console,'(?m)^\s*(?:#\s*)?HDMI_SHARED_FONT_PIXELS_PASS\b.*$')
    if($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or $passes.Count -ne 2) {
        throw "Shared font verification did not pass: $simulationDir/console.log"
    }
    $passes | ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
} finally {
    Pop-Location
}
