param(
    [string] $DetectorSource = '',
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [int] $Threshold = 6,
    [int] $SpatialVotes = 3,
    [int] $MinBlocks = 8,
    [switch] $RequireDetections
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $DetectorSource) {
    $DetectorSource = Join-Path $projectRoot 'user_source\hdl_source\isp\motion_target_detect_96.v'
}
$simulationDir = Join-Path $env:TEMP ('anlogic_motion_realistic_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$detectorCopy = Join-Path $simulationDir 'motion_target_detect_96.v'
$testbenchCopy = Join-Path $simulationDir 'tb_motion_realistic.sv'
Copy-Item -LiteralPath $DetectorSource -Destination $detectorCopy
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_motion_realistic.sv') -Destination $testbenchCopy
$requireParameter = [int] $RequireDetections.IsPresent
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv -d MOTION_PORTABLE_RAM $detectorCopy $testbenchCopy `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw "Realistic motion compile failed; see $simulationDir\compile_console.log" }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        -generic_top "`"DIFF_THRESHOLD=$Threshold`"" -generic_top "`"SPATIAL_VOTES=$SpatialVotes`"" `
        -generic_top "`"MIN_BLOCKS=$MinBlocks`"" -generic_top "`"REQUIRE_DETECTIONS=$requireParameter`"" `
        work.tb_motion_realistic -s motion_realistic -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw "Realistic motion elaboration failed; see $simulationDir\elaborate_console.log" }
    & (Join-Path $SimBin 'xsim.bat') motion_realistic -runall -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw "Realistic motion simulation failed; see $simulationDir\simulate_console.log" }
    $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match '(?im)^\s*(?:Fatal:|\*\*\s+(?:Fatal|Error)\b)' -or
        $console -notmatch '(?m)^MOTION_REALISTIC_PASS\b') {
        throw "Realistic motion did not pass; see $simulationDir\simulate_console.log"
    }
    [regex]::Match($console, '(?m)^MOTION_REALISTIC_PASS.*$').Value
} finally {
    Pop-Location
}
