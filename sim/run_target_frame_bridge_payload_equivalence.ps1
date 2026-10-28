param(
    [string] $ReferenceRtl = '',
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ReferenceRtl) {
    $ReferenceRtl = Join-Path $projectRoot 'build\slice_compression\baseline_project\user_source\hdl_source\target_frame_bridge.v'
}
$ReferenceRtl = (Resolve-Path -LiteralPath $ReferenceRtl).Path
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_bridge_payload_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    (Join-Path $PSScriptRoot 'reference\ph1p_logic_dram_asym_sim.v'),
    (Join-Path $projectRoot 'user_source\hdl_source\target_frame_bridge.v'),
    (Join-Path $PSScriptRoot 'tb_target_frame_bridge_payload_equivalence.sv')
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
$referenceCopy = Join-Path $simulationDir 'target_frame_bridge_reference.v'
$referenceText = [IO.File]::ReadAllText($ReferenceRtl)
$referenceText = [regex]::Replace($referenceText,
    '\btarget_frame_bridge\b', 'target_frame_bridge_reference')
[IO.File]::WriteAllText($referenceCopy, $referenceText, [Text.UTF8Encoding]::new($false))
$compiledSources += $referenceCopy
$referenceHash = (Get-FileHash -LiteralPath $ReferenceRtl -Algorithm SHA256).Hash
$hashes += [pscustomobject]@{
    File = Split-Path -Leaf $referenceCopy
    Source = $ReferenceRtl
    SHA256 = $referenceHash
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
Write-Output "Reference SHA256: $referenceHash"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @compiledSources `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Payload differential compile failed: $simulationDir\compile_console.log"
    }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug all `
        work.tb_target_frame_bridge_payload_equivalence -s bridge_payload `
        -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Payload differential elaboration failed: $simulationDir\elaborate_console.log"
    }
    & (Join-Path $SimBin 'xsim.bat') bridge_payload -runall `
        -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Payload differential simulation failed: $simulationDir\simulate_console.log"
    }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
        [regex]::Matches($console, '(?m)^TARGET_FRAME_BRIDGE_PAYLOAD_CASE_PASS\b').Count -ne 5 -or
        [regex]::Matches($console, '(?m)^TARGET_FRAME_BRIDGE_PAYLOAD_EQUIVALENCE_PASS\b').Count -ne 1) {
        throw "Payload differential did not pass: $simulationDir\simulate_console.log"
    }
    Select-String -LiteralPath simulate_console.log -Pattern '^TARGET_FRAME_BRIDGE_PAYLOAD_.*PASS\b' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
