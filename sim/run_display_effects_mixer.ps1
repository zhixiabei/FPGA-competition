param(
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sources = @(
    'user_source\hdl_source\camera_diag_cdc.v',
    'user_source\hdl_source\display_effect_control.v',
    'user_source\hdl_source\display_effects_rgb888.v',
    'user_source\hdl_source\gamma_lut_rgb888.v',
    'user_source\hdl_source\hdmi_mixer.v',
    'user_source\hdl_source\anlogic_logo_rom.v',
    'user_source\hdl_source\osd_char_lib.v',
    'sim\tb_display_effects_mixer.sv',
    'sim\tb_color_target_mixer.sv'
)
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_display_effects_mixer_' + [guid]::NewGuid().ToString('N'))
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
foreach top {tb_display_effects_mixer tb_color_target_mixer} {
    vsim -novopt -onfinish stop -t ps work.`$top
    run -all
    quit -sim
}
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript, [Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Display effect mixer simulation failed: $simulationDir\console.log"
    }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b') {
        throw "Display effect mixer simulation reported an error: $simulationDir\console.log"
    }
    foreach ($pattern in @('DISPLAY_EFFECTS_MIXER_PASS', 'COLOR_TARGET_MIXER_PASS')) {
        $matches = [regex]::Matches($console, "(?m)^\s*(?:#\s*)?$pattern\b.*$")
        if ($matches.Count -ne 1) {
            throw "Display effect mixer regression did not pass: $simulationDir\console.log"
        }
        $matches[0].Value.Trim() -replace '^#\s*', ''
    }
} finally {
    Pop-Location
}
