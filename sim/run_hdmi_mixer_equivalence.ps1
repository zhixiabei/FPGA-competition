param(
    [Parameter(Mandatory = $true)]
    [string] $BaselineDir,
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string[]] $AdditionalSources = @(),
    [string[]] $Defines = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'user_source\hdl_source'
$baselineRoot = (Resolve-Path -LiteralPath $BaselineDir).Path
$sourceNames = @('hdmi_mixer.v', 'anlogic_logo_rom.v', 'osd_char_lib.v')

foreach ($name in $sourceNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $baselineRoot $name) -PathType Leaf)) {
        throw "Baseline source is missing: $name"
    }
}
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}

$simulationDir = Join-Path $env:TEMP ('anlogic_mixer_equivalence_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$baselineSources = @()
foreach ($name in $sourceNames) {
    $text = [IO.File]::ReadAllText((Join-Path $baselineRoot $name))
    # Namespace only module identifiers; retain the frozen source logic/data.
    $text = [regex]::Replace($text, '\b(hdmi_mixer|anlogic_logo_rom|osd_char_lib)\b', 'baseline_$1')
    $path = Join-Path $simulationDir ('baseline_' + $name)
    [IO.File]::WriteAllText($path, $text, [Text.Encoding]::ASCII)
    $baselineSources += $path
}
$candidateSources = @()
foreach ($name in $sourceNames) {
    $path = Join-Path $simulationDir $name
    Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination $path
    $candidateSources += $path
}

Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    $compileArgs = @('-sv')
    foreach ($define in $Defines) {
        $compileArgs += @('-d', $define)
    }
    $compileArgs += $baselineSources + $candidateSources + $AdditionalSources +
        @(Join-Path $PSScriptRoot 'tb_hdmi_mixer_equivalence.sv') + @('-log', 'xvlog.log')
    & (Join-Path $SimBin 'xvlog.bat') @compileArgs *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim compile failed; see compile_console.log' }

    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        work.tb_hdmi_mixer_equivalence -s mixer_equivalence -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim elaboration failed; see elaborate_console.log' }

    & (Join-Path $SimBin 'xsim.bat') mixer_equivalence -runall -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim simulation failed; see simulate_console.log' }
    $pass = Select-String -LiteralPath simulate_console.log -Pattern '^HDMI_MIXER_EQUIVALENCE_PASS'
    if (-not $pass) { throw 'Equivalence did not pass; see simulate_console.log' }
    $pass.Line
} finally {
    Pop-Location
}
