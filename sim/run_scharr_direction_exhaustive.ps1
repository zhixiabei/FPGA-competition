param(
    [string] $ReferenceRtl = '',
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ReferenceRtl) {
    $ReferenceRtl = Join-Path $projectRoot 'build\slice_compression\baseline_project\user_source\hdl_source\isp\scharr_edge_detect_96.v'
}
$ReferenceRtl = (Resolve-Path -LiteralPath $ReferenceRtl).Path
foreach ($tool in @('xvlog.bat','xelab.bat','xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "Missing XSim tool: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_scharr_direction_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$candidate = Join-Path $projectRoot 'user_source\hdl_source\isp\scharr_edge_detect_96.v'
$candidateCopy = Join-Path $simulationDir 'scharr_edge_detect_96.v'
Copy-Item -LiteralPath $candidate -Destination $candidateCopy
$baselineCopy = Join-Path $simulationDir 'scharr_edge_detect_96_reference.v'
$baselineText = [IO.File]::ReadAllText($ReferenceRtl)
$baselineText = [regex]::Replace($baselineText,'\bscharr_edge_detect_96\b','scharr_edge_detect_96_reference')
$baselineText = [regex]::Replace($baselineText,'\bscharr_window_4\b','scharr_window_4_reference')
[IO.File]::WriteAllText($baselineCopy,$baselineText,[Text.UTF8Encoding]::new($false))
$testbench = Join-Path $simulationDir 'tb_scharr_direction_exhaustive.sv'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_scharr_direction_exhaustive.sv') -Destination $testbench
@(
    [pscustomobject]@{Role='Candidate';Source=$candidate;SHA256=(Get-FileHash -LiteralPath $candidateCopy -Algorithm SHA256).Hash},
    [pscustomobject]@{Role='BaselineBeforeRename';Source=$ReferenceRtl;SHA256=(Get-FileHash -LiteralPath $ReferenceRtl -Algorithm SHA256).Hash},
    [pscustomobject]@{Role='Testbench';Source=$testbench;SHA256=(Get-FileHash -LiteralPath $testbench -Algorithm SHA256).Hash}
) | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv -d SCHARR_PORTABLE_RAM `
        $candidateCopy $baselineCopy $testbench -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $simulationDir\compile_console.log" }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        work.tb_scharr_direction_exhaustive -s scharr_direction_exhaustive -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw "Elaboration failed: $simulationDir\elaborate_console.log" }
    & (Join-Path $SimBin 'xsim.bat') scharr_direction_exhaustive -runall -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $simulationDir\simulate_console.log" }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
        [regex]::Matches($console,'(?m)^SCHARR_DIRECTION_EXHAUSTIVE_PASS\b').Count -ne 1) {
        throw "Scharr actual-function exhaustive regression failed: $simulationDir\simulate_console.log"
    }
    Select-String -LiteralPath simulate_console.log -Pattern '^SCHARR_DIRECTION_EXHAUSTIVE_PASS' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
