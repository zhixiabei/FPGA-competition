param(
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sources = @(
    'user_source\hdl_source\display_effects_rgb888.v',
    'user_source\hdl_source\gamma_lut_rgb888.v',
    'user_source\hdl_source\hdmi_mixer.v',
    'user_source\hdl_source\anlogic_logo_rom.v',
    'user_source\hdl_source\osd_char_lib.v',
    'sim\tb_multi_target_mixer.sv'
)
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_multi_target_mixer_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources = @()
foreach ($relative in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $destination
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
onbreak {resume}
vlib work
vlog -sv $tclSources
vsim -novopt -onfinish stop -t ps work.tb_multi_target_mixer
run -all
quit -sim
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript, [Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Multi-target mixer simulation failed: $simulationDir\console.log"
    }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b') {
        throw "Multi-target mixer simulation reported an error: $simulationDir\console.log"
    }
    $matches = [regex]::Matches($console, '(?m)^\s*(?:#\s*)?MULTI_TARGET_MIXER_PASS\b.*$')
    if ($matches.Count -ne 1) {
        throw "Multi-target mixer verification did not pass: $simulationDir\console.log"
    }
    $matches[0].Value.Trim() -replace '^#\s*', ''
} finally {
    Pop-Location
}
