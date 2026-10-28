param(
    [string] $ReferenceRtl='',
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
if(-not $ReferenceRtl) {
    $ReferenceRtl=Join-Path $projectRoot 'build/timing_resource_repair_20261027/baseline/user_source/hdl_source/hdmi_mixer.v'
}
$simulationDir=Join-Path $env:TEMP ('anlogic_hdmi_runtime_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources=@('hdmi_mixer.v','display_effects_rgb888.v','gamma_lut_rgb888.v',
    'anlogic_logo_rom.v','osd_char_lib.v','video_latency_osd.v','raw_stats_osd.v')
foreach($source in $sources) {
    Copy-Item -LiteralPath (Join-Path $projectRoot ('user_source/hdl_source/'+$source)) `
        -Destination (Join-Path $simulationDir $source)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_hdmi_runtime_equivalence.sv') `
    -Destination $simulationDir
$referenceText=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $ReferenceRtl))
$referenceText=[regex]::Replace($referenceText,'\bhdmi_mixer\b','hdmi_mixer_reference')
[IO.File]::WriteAllText((Join-Path $simulationDir 'hdmi_mixer_reference.v'),
    $referenceText,[Text.UTF8Encoding]::new($false))
$sourceFiles=@(Get-ChildItem -LiteralPath $simulationDir -File)
$sourceFiles | Get-FileHash -Algorithm SHA256 |
    Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$compile=@($sources+'hdmi_mixer_reference.v'+'tb_hdmi_runtime_equivalence.sv') -join ' '
$runScript=@"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $compile
vsim -t ps work.tb_hdmi_runtime_equivalence -gPROBE=0 -gRUNTIME=1 -gFRUIT=1
onfinish stop
run -all
quit -sim
vsim -t ps work.tb_hdmi_runtime_equivalence -gPROBE=1 -gRUNTIME=1 -gFRUIT=1
onfinish stop
run -all
quit -sim
vsim -t ps work.tb_hdmi_runtime_equivalence -gPROBE=0 -gRUNTIME=0 -gFRUIT=0
onfinish stop
run -all
quit -sim
foreach debug {1 2 3} {
    vsim -t ps work.tb_hdmi_runtime_equivalence -gDEBUG=`$debug
    onfinish stop
    run -all
    quit -sim
}
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if($LASTEXITCODE -ne 0) {
        throw "HDMI runtime simulation failed: $simulationDir/console.log"
    }
    $console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    $passes=[regex]::Matches($console,'(?m)^\s*(?:#\s*)?HDMI_RUNTIME_EQUIVALENCE_PASS\b.*$')
    $debugPasses=[regex]::Matches($console,'(?m)^\s*(?:#\s*)?HDMI_DEBUG_EQUIVALENCE_PASS\b.*$')
    if($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
        $passes.Count -ne 3 -or $debugPasses.Count -ne 3) {
        throw "HDMI runtime verification did not pass all variants: $simulationDir/console.log"
    }
    $passes | ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
    $debugPasses | ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
} finally {
    Pop-Location
}
