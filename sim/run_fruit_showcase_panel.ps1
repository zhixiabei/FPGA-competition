param(
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
$simulationDir=Join-Path $env:TEMP ('anlogic_fruit_showcase_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources=@('hdmi_mixer.v','display_effects_rgb888.v','gamma_lut_rgb888.v',
    'anlogic_logo_rom.v','osd_char_lib.v','video_latency_osd.v','raw_stats_osd.v')
foreach($source in $sources) {
    Copy-Item -LiteralPath (Join-Path $projectRoot ('user_source/hdl_source/'+$source)) `
        -Destination (Join-Path $simulationDir $source)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_fruit_showcase_panel.sv') `
    -Destination $simulationDir
$compile=@($sources+'tb_fruit_showcase_panel.sv') -join ' '
$runScript=@"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $compile
vsim -t ps work.tb_fruit_showcase_panel
onfinish stop
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if($LASTEXITCODE -ne 0) {
        throw "Fruit showcase simulation failed: $simulationDir/console.log"
    }
    $console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    $passes=[regex]::Matches($console,
        '(?m)^\s*(?:#\s*)?FRUIT_SHOWCASE_PANEL_PASS\b.*$')
    if($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
        $passes.Count -ne 1) {
        throw "Fruit showcase verification did not pass: $simulationDir/console.log"
    }
    $passes | ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
} finally {
    Pop-Location
}
