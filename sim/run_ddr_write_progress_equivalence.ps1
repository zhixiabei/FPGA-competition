param(
    [string] $CandidateRoot = '',
    [string] $ReferenceRoot = '',
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $CandidateRoot) {
    $CandidateRoot = Join-Path $projectRoot 'build\slice_compression\candidates\ddr_count'
}
if (-not $ReferenceRoot) {
    $ReferenceRoot = Join-Path $projectRoot 'build\slice_compression\baseline_project'
}
$CandidateRoot = (Resolve-Path -LiteralPath $CandidateRoot).Path
$ReferenceRoot = (Resolve-Path -LiteralPath $ReferenceRoot).Path
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_ddr_progress_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    (Join-Path $CandidateRoot 'user_source\hdl_source\target_frame_bridge.v'),
    (Join-Path $CandidateRoot 'user_source\hdl_source\video_latency_monitor.v'),
    (Join-Path $ReferenceRoot 'user_source\hdl_source\video_latency_timebase.v'),
    (Join-Path $PSScriptRoot 'tb_ddr_write_progress_equivalence.sv')
)
$compiledSources = @()
$hashes = foreach ($source in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $destination
    $compiledSources += $destination
    [pscustomobject]@{
        File = Split-Path -Leaf $source
        Source = $source
        SHA256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    }
}
foreach ($moduleName in @('target_frame_bridge','video_latency_monitor')) {
    $source = Join-Path $ReferenceRoot ('user_source\hdl_source\' + $moduleName + '.v')
    $destination = Join-Path $simulationDir ($moduleName + '_reference.v')
    $referenceText = [IO.File]::ReadAllText($source)
    $referenceText = [regex]::Replace($referenceText,
        ('\b' + $moduleName + '\b'), ($moduleName + '_reference'))
    [IO.File]::WriteAllText($destination, $referenceText, [Text.UTF8Encoding]::new($false))
    $compiledSources += $destination
    $hashes += [pscustomobject]@{
        File = Split-Path -Leaf $destination
        Source = $source
        SHA256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
Write-Output "Candidate root: $CandidateRoot"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @compiledSources `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "DDR progress compile failed: $simulationDir\compile_console.log"
    }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug all `
        work.tb_ddr_write_progress_equivalence -s ddr_progress `
        -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "DDR progress elaboration failed: $simulationDir\elaborate_console.log"
    }
    & (Join-Path $SimBin 'xsim.bat') ddr_progress -runall `
        -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "DDR progress simulation failed: $simulationDir\simulate_console.log"
    }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
        [regex]::Matches($console, '(?m)^DDR_WRITE_PROGRESS_CASE_PASS\b').Count -ne 7 -or
        [regex]::Matches($console, '(?m)^DDR_WRITE_PROGRESS_EQUIVALENCE_PASS\b').Count -ne 1) {
        throw "DDR progress differential did not pass: $simulationDir\simulate_console.log"
    }
    Select-String -LiteralPath simulate_console.log -Pattern '^DDR_WRITE_PROGRESS_.*PASS\b' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
