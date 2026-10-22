param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'user_source\hdl_source'
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_ae_histogram_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    (Join-Path $sourceRoot 'isp\ae_frame_stats_raw10_4x.v'),
    (Join-Path $sourceRoot 'ae_stats_cdc.v'),
    (Join-Path $PSScriptRoot 'tb_ae_histogram.sv'),
    (Join-Path $PSScriptRoot 'tb_ae_histogram_cdc.sv')
)
$snapshotDirectory = Join-Path $simulationDir 'sources'
New-Item -ItemType Directory -Path $snapshotDirectory | Out-Null
$compiledSources = @()
$sourceHashes = foreach ($source in $sources) {
    $snapshot = Join-Path $snapshotDirectory (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $snapshot
    $compiledSources += $snapshot
    [pscustomobject]@{
        Path = $source.Substring($projectRoot.Length + 1).Replace('\', '/')
        SHA256 = (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
    }
}
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$tests = @(
    @{Name = 'histogram_sparse'; Width = 64; Height = 16; GroupLog2 = 3; FullSuite = 1},
    @{Name = 'histogram_dense'; Width = 64; Height = 16; GroupLog2 = 2; FullSuite = 1},
    @{Name = 'histogram_short_tail'; Width = 144; Height = 3; GroupLog2 = 2; FullSuite = 0},
    @{Name = 'histogram_720p'; Width = 1280; Height = 720; GroupLog2 = 3; FullSuite = 0},
    @{Name = 'histogram_count_bound'; Width = 65520; Height = 16; GroupLog2 = 2; FullSuite = 0}
)
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @compiledSources -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim compile failed; see compile_console.log' }
    foreach ($test in $tests) {
        $generics = @(
            '-generic_top', ('"WIDTH=' + $test.Width + '"'),
            '-generic_top', ('"HEIGHT=' + $test.Height + '"'),
            '-generic_top', ('"GROUP_LOG2=' + $test.GroupLog2 + '"'),
            '-generic_top', ('"FULL_SUITE=' + $test.FullSuite + '"')
        )
        $elaborateLog = $test.Name + '_elaborate_console.log'
        $simulationLog = $test.Name + '_simulate_console.log'
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            work.tb_ae_histogram @generics -s $test.Name -log ($test.Name + '_xelab.log') *> $elaborateLog
        if ($LASTEXITCODE -ne 0) { throw "XSim elaboration failed; see $elaborateLog" }
        & (Join-Path $SimBin 'xsim.bat') $test.Name -runall `
            -log ($test.Name + '_xsim.log') *> $simulationLog
        if ($LASTEXITCODE -ne 0) { throw "XSim simulation failed; see $simulationLog" }
        $pass = Select-String -LiteralPath $simulationLog -Pattern '^AE_HISTOGRAM_PASS'
        if (-not $pass) { throw "Test did not pass; see $simulationLog" }
        $pass.Line
    }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        work.tb_ae_histogram_cdc -s histogram_cdc -log histogram_cdc_xelab.log *> histogram_cdc_elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim CDC elaboration failed; see histogram_cdc_elaborate_console.log' }
    & (Join-Path $SimBin 'xsim.bat') histogram_cdc -runall `
        -log histogram_cdc_xsim.log *> histogram_cdc_simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim CDC simulation failed; see histogram_cdc_simulate_console.log' }
    $cdcPass = Select-String -LiteralPath histogram_cdc_simulate_console.log -Pattern '^AE_HISTOGRAM_CDC_PASS'
    if (-not $cdcPass) { throw 'Integrated CDC test did not pass; see histogram_cdc_simulate_console.log' }
    $cdcPass.Line
    foreach ($kind in 0..4) {
        $name = 'histogram_reject_' + $kind
        $elaborateLog = $name + '_elaborate_console.log'
        $simulationLog = $name + '_simulate_console.log'
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            work.tb_ae_histogram_unsupported -generic_top ('"KIND=' + $kind + '"') `
            -s $name -log ($name + '_xelab.log') *> $elaborateLog
        if ($LASTEXITCODE -ne 0) { throw "XSim elaboration failed; see $elaborateLog" }
        & (Join-Path $SimBin 'xsim.bat') $name -runall `
            -log ($name + '_xsim.log') *> $simulationLog
        $reason = if ($kind -eq 4) {
            'AE RAW statistics count exceeds the 16-bit interface'
        } else {
            'Histogram needs >=4 clocks between groups and 8..32 bins'
        }
        $reject = Select-String -LiteralPath $simulationLog -SimpleMatch -Pattern $reason
        if (-not $reject) { throw "Expected parameter rejection was absent; see $simulationLog" }
        Write-Output "AE_HISTOGRAM_PARAMETER_REJECT_PASS kind=$kind reason=$reason"
    }
} finally {
    Pop-Location
}
