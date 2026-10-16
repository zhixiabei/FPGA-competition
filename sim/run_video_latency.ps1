param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_video_latency_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$relativeSources = @(
    'user_source\hdl_source\video_latency_monitor.v',
    'user_source\hdl_source\video_latency_timebase.v',
    'user_source\hdl_source\ae_stats_cdc.v',
    'sim\tb_video_latency_timebase.sv',
    'sim\tb_video_latency_monitor.sv',
    'sim\tb_video_latency_word_count.sv'
)
$copiedSources = @()
foreach ($relative in $relativeSources) {
    $source = Join-Path $projectRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Latency source is missing: $source"
    }
    $destination = Join-Path $simulationDir (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $destination
    $copiedSources += $destination
}
$hashes = foreach ($source in $copiedSources) {
    $hash = Get-FileHash -LiteralPath $source -Algorithm SHA256
    [pscustomobject]@{ File = (Split-Path -Leaf $source); SHA256 = $hash.Hash }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$tests = @(
    @{ Top = 'tb_video_latency_timebase'; Snapshot = 'latency_timebase'; Pass = '^VIDEO_LATENCY_TIMEBASE_PASS\b' },
    @{ Top = 'tb_video_latency_monitor'; Snapshot = 'latency_monitor'; Pass = '^VIDEO_LATENCY_MONITOR_PASS\b' },
    @{ Top = 'tb_video_latency_word_count'; Snapshot = 'latency_word_count'; Pass = '^VIDEO_LATENCY_WORD_COUNT_PASS\b' }
)
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @copiedSources -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) {
        throw "XSim compile failed: $simulationDir\compile_console.log"
    }
    foreach ($test in $tests) {
        $elaborateLog = $test.Snapshot + '_elaborate_console.log'
        $simulationLog = $test.Snapshot + '_simulate_console.log'
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            ('work.' + $test.Top) -s $test.Snapshot `
            -log ($test.Snapshot + '_xelab.log') *> $elaborateLog
        if ($LASTEXITCODE -ne 0) {
            throw "XSim elaboration failed: $simulationDir\$elaborateLog"
        }
        & (Join-Path $SimBin 'xsim.bat') $test.Snapshot -runall `
            -log ($test.Snapshot + '_xsim.log') *> $simulationLog
        if ($LASTEXITCODE -ne 0) {
            throw "XSim simulation failed: $simulationDir\$simulationLog"
        }
        $console = [IO.File]::ReadAllText((Join-Path $simulationDir $simulationLog))
        if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
            [regex]::Matches($console, '(?m)' + $test.Pass).Count -ne 1) {
            throw "Latency regression did not pass: $simulationDir\$simulationLog"
        }
        Select-String -LiteralPath $simulationLog -Pattern $test.Pass |
            ForEach-Object { $_.Line }
    }
} finally {
    Pop-Location
}
