param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $ControllerPath = '',
    [string] $OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ControllerPath) {
    $ControllerPath = Join-Path $projectRoot 'user_source\hdl_source\auto_exposure_control.v'
}
$controller = (Resolve-Path -LiteralPath $ControllerPath).Path
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = if ($OutputDirectory) {
    [IO.Path]::GetFullPath($OutputDirectory)
} else {
    Join-Path $env:TEMP ('anlogic_ae_arithmetic_' + [guid]::NewGuid().ToString('N'))
}
if (Test-Path -LiteralPath $simulationDir) {
    throw "Output directory must be new: $simulationDir"
}
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sourceDirectory = Join-Path $simulationDir 'sources'
New-Item -ItemType Directory -Path $sourceDirectory | Out-Null
$sources = @($controller, (Join-Path $PSScriptRoot 'tb_ae_control_arithmetic.sv'))
$compiledSources = @()
$sourceHashes = foreach ($source in $sources) {
    $snapshot = Join-Path $sourceDirectory (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $snapshot
    $compiledSources += $snapshot
    [pscustomobject]@{
        Source = $source
        Snapshot = 'sources/' + (Split-Path -Leaf $source)
        SHA256 = (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
    }
}
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $simulationDir 'run_ae_control_arithmetic.ps1')
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @compiledSources -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'Arithmetic probe compilation failed; see compile_console.log' }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        work.tb_ae_control_arithmetic -s ae_control_arithmetic -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'Arithmetic probe elaboration failed; see elaborate_console.log' }
    & (Join-Path $SimBin 'xsim.bat') ae_control_arithmetic -runall `
        -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'Arithmetic probe simulation failed; see simulate_console.log' }
    $pass = Select-String -LiteralPath simulate_console.log -Pattern '^AE_CONTROL_ARITHMETIC_PASS'
    if (-not $pass) {
        Get-Content -LiteralPath simulate_console.log -Tail 15
        throw 'Arithmetic probe did not pass; see simulate_console.log'
    }
    $pass.Line
} finally {
    Pop-Location
}
