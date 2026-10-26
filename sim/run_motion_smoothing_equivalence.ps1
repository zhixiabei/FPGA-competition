param(
    [string] $SwitchSource = '',
    [int] $TimeoutSeconds = 180,
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $SwitchSource) {
    $SwitchSource = Join-Path $projectRoot 'user_source\hdl_source\isp\target_detect_switch_96.v'
}
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
if ($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
$simulationDir = Join-Path $env:TEMP ('anlogic_motion_smoothing_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources = @()
foreach ($source in @($SwitchSource, (Join-Path $PSScriptRoot 'tb_motion_smoothing_equivalence.sv'))) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $destination
    $compiledSources += $destination
}
$hashes = foreach ($source in $compiledSources) {
    [pscustomobject]@{
        File = Split-Path -Leaf $source
        SHA256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$tclSources = ($compiledSources | ForEach-Object { '{' + $_.Replace('\', '/') + '}' }) -join ' '
$runScript = @"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv $tclSources
vsim -t ps work.tb_motion_smoothing_equivalence
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript, [Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Write-Output "Switch source SHA256: $($hashes[0].SHA256)"
$consolePath = Join-Path $simulationDir 'console.log'
$errorPath = Join-Path $simulationDir 'stderr.log'
$process = Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
    -ArgumentList @('-c', '-do', 'run.do', '-l', 'transcript.log') `
    -WorkingDirectory $simulationDir -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $consolePath -RedirectStandardError $errorPath
if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $process.Id -Force
    throw "Smoothing equivalence timed out: $consolePath"
}
$process.WaitForExit()
$console = [IO.File]::ReadAllText($consolePath)
if ($process.ExitCode -ne 0 -or
    $console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
    $console -notmatch '(?m)^\s*(?:#\s*)?MOTION_SMOOTHING_EQUIVALENCE_PASS\b') {
    throw "Smoothing equivalence failed: $consolePath"
}
[regex]::Matches($console,
    '(?m)^\s*(?:#\s*)?MOTION_SMOOTHING_(?:CASE|EQUIVALENCE)_PASS\b.*$') |
    ForEach-Object { $_.Value.Trim() -replace '^#\s*', '' }
