param(
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
$simulationDir=Join-Path $env:TEMP ('anlogic_osd_char_rom_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'user_source/hdl_source/osd_char_lib.v') -Destination $simulationDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_osd_char_rom_equivalence.sv') -Destination $simulationDir
$sourceFiles=@(Get-ChildItem -LiteralPath $simulationDir -File)
$sourceFiles | Get-FileHash -Algorithm SHA256 |
    Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$runScript=@"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv osd_char_lib.v tb_osd_char_rom_equivalence.sv
vsim -t ps work.tb_osd_char_rom_equivalence
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
        throw "Font ROM simulation failed: $simulationDir/console.log"
    }
    $console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    $passes=[regex]::Matches($console,'(?m)^\s*(?:#\s*)?OSD_CHAR_ROM_EQUIVALENCE_PASS\b.*$')
    if($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or $passes.Count -ne 1) {
        throw "Font ROM verification did not pass: $simulationDir/console.log"
    }
    $passes[0].Value.Trim() -replace '^#\s*',''
} finally {
    Pop-Location
}
