param(
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_motion_stabilizer_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sourceFiles = @(
    (Join-Path $projectRoot 'user_source\hdl_source\isp\target_detect_switch_96.v'),
    (Join-Path $PSScriptRoot 'tb_motion_result_stabilizer.sv')
)
$compiledSources = @()
foreach ($source in $sourceFiles) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $destination
    $compiledSources += $destination
}
$sourceHash = (Get-FileHash -LiteralPath $compiledSources[0] -Algorithm SHA256).Hash
$tclSources = ($compiledSources | ForEach-Object { '{' + $_.Replace('\', '/') + '}' }) -join ' '
$runScript = @"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv $tclSources
vsim -t ps work.tb_motion_result_stabilizer
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript, [Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Write-Output "Stabilizer source SHA256: $sourceHash"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Motion stabilizer simulation failed: $simulationDir\console.log"
    }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
        $console -notmatch '(?m)^\s*(?:#\s*)?MOTION_RESULT_STABILIZER_PASS\b') {
        throw "Motion stabilizer regression did not pass: $simulationDir\console.log"
    }
    Select-String -LiteralPath console.log -Pattern 'MOTION_RESULT_STABILIZER_PASS' |
        ForEach-Object { $_.Line -replace '^#\s*', '' }
} finally {
    Pop-Location
}
