param(
    [string] $CandidateRtl = '',
    [string] $ReferenceRtl = '',
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $CandidateRtl) {
    $CandidateRtl = Join-Path $projectRoot 'build\slice_compression\candidates\bridge_clip\user_source\hdl_source\target_frame_bridge.v'
}
if (-not $ReferenceRtl) {
    $ReferenceRtl = Join-Path $projectRoot 'build\slice_compression\baseline_project\user_source\hdl_source\target_frame_bridge.v'
}
$CandidateRtl = (Resolve-Path -LiteralPath $CandidateRtl).Path
$ReferenceRtl = (Resolve-Path -LiteralPath $ReferenceRtl).Path
foreach ($tool in @('xvlog.bat','xelab.bat','xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "Missing XSim tool: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_bridge_clip_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$candidateCopy = Join-Path $simulationDir 'target_frame_bridge.v'
Copy-Item -LiteralPath $CandidateRtl -Destination $candidateCopy
$referenceCopy = Join-Path $simulationDir 'target_frame_bridge_reference.v'
$referenceText = [IO.File]::ReadAllText($ReferenceRtl)
if ([regex]::Matches($referenceText,'\bmodule\s+target_frame_bridge\b').Count -ne 1) {
    throw 'Expected exactly one target_frame_bridge declaration in frozen baseline'
}
[IO.File]::WriteAllText($referenceCopy,
    [regex]::Replace($referenceText,'\bmodule\s+target_frame_bridge\b','module target_frame_bridge_reference'),
    [Text.UTF8Encoding]::new($false))
$testbenchCopy = Join-Path $simulationDir 'tb_bridge_clip_equivalence.sv'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_bridge_clip_equivalence.sv') -Destination $testbenchCopy
@(
    [pscustomobject]@{Role='Candidate';Source=$CandidateRtl;SHA256=(Get-FileHash -LiteralPath $candidateCopy -Algorithm SHA256).Hash},
    [pscustomobject]@{Role='BaselineBeforeRename';Source=$ReferenceRtl;SHA256=(Get-FileHash -LiteralPath $ReferenceRtl -Algorithm SHA256).Hash},
    [pscustomobject]@{Role='Testbench';Source=$testbenchCopy;SHA256=(Get-FileHash -LiteralPath $testbenchCopy -Algorithm SHA256).Hash}
) | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv $candidateCopy $referenceCopy $testbenchCopy `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $simulationDir\compile_console.log" }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        work.tb_bridge_clip_equivalence -s bridge_clip_equivalence -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw "Elaboration failed: $simulationDir\elaborate_console.log" }
    & (Join-Path $SimBin 'xsim.bat') bridge_clip_equivalence -runall -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $simulationDir\simulate_console.log" }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
        [regex]::Matches($console,'(?m)^BRIDGE_CLIP_EQUIVALENCE_PASS\b').Count -ne 1) {
        throw "Bridge clip regression failed: $simulationDir\simulate_console.log"
    }
    Select-String -LiteralPath simulate_console.log -Pattern '^BRIDGE_CLIP_EQUIVALENCE_PASS' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
