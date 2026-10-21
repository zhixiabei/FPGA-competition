param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p',
    [string] $ReferenceRoot = '',
    [ValidateSet('Both', 'Awb', 'Latency')]
    [string] $Mode = 'Both'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ReferenceRoot) {
    $ReferenceRoot = Join-Path $projectRoot 'build\slice_compression\baseline_project'
}
foreach ($tool in @('xvlog.bat','xelab.bat','xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "Missing XSim tool: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_awb_latency_equivalence_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @()
$tests = @()
function Add-DifferentialSource([string] $module) {
    $relative = 'user_source\hdl_source\' + $module + '.v'
    $current = Join-Path $projectRoot $relative
    $baseline = Join-Path $ReferenceRoot $relative
    if (-not (Test-Path -LiteralPath $baseline -PathType Leaf)) {
        throw "Frozen baseline missing: $baseline"
    }
    $candidateCopy = Join-Path $simulationDir ($module + '.v')
    Copy-Item -LiteralPath $current -Destination $candidateCopy
    $baselineCopy = Join-Path $simulationDir ($module + '_baseline.v')
    $original = [IO.File]::ReadAllText($baseline)
    $pattern = '\bmodule\s+' + [regex]::Escape($module) + '\b'
    if ([regex]::Matches($original,$pattern).Count -ne 1) {
        throw "Expected exactly one module declaration in $baseline"
    }
    [IO.File]::WriteAllText($baselineCopy,
        [regex]::Replace($original,$pattern,('module ' + $module + '_baseline')),
        [Text.UTF8Encoding]::new($false))
    return @($candidateCopy,$baselineCopy)
}
if ($Mode -in @('Both','Awb')) {
    $sources += Add-DifferentialSource 'awb'
    $dramText = [IO.File]::ReadAllText((Join-Path $TdSimLib 'ph1p_logic_dram.v'))
    $dramModule = [regex]::Match($dramText,'(?s)\A.*?\bendmodule\b')
    if (-not $dramModule.Success -or
        -not $dramModule.Value.Contains('module PH1P_LOGIC_DRAM')) {
        throw 'Functional TD DRAM model was not found'
    }
    $dramCopy = Join-Path $simulationDir 'ph1p_logic_dram.v'
    [IO.File]::WriteAllText($dramCopy,$dramModule.Value,[Text.UTF8Encoding]::new($false))
    $sources += $dramCopy
    $tb = Join-Path $simulationDir 'tb_awb_width_equivalence.sv'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_awb_width_equivalence.sv') -Destination $tb
    $sources += $tb
    $tests += @{ Top='tb_awb_width_equivalence'; Snapshot='awb_width_equivalence'; Pass='^AWB_WIDTH_EQUIVALENCE_PASS\b' }
}
if ($Mode -in @('Both','Latency')) {
    $sources += Add-DifferentialSource 'video_latency_monitor'
    $timebase = Join-Path $simulationDir 'video_latency_timebase.v'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'user_source\hdl_source\video_latency_timebase.v') -Destination $timebase
    $sources += $timebase
    $tb = Join-Path $simulationDir 'tb_latency_shared_equivalence.sv'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_latency_shared_equivalence.sv') -Destination $tb
    $sources += $tb
    $tests += @{ Top='tb_latency_shared_equivalence'; Snapshot='latency_shared_equivalence'; Pass='^LATENCY_SHARED_EQUIVALENCE_PASS\b' }
}
$hashes = foreach ($source in $sources) {
    [pscustomobject]@{
        File = Split-Path -Leaf $source
        SHA256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @sources -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $simulationDir\compile_console.log" }
    foreach ($test in $tests) {
        $elaborateLog = $test.Snapshot + '_elaborate_console.log'
        $simulateLog = $test.Snapshot + '_simulate_console.log'
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            ('work.'+$test.Top) -s $test.Snapshot -log ($test.Snapshot+'_xelab.log') *> $elaborateLog
        if ($LASTEXITCODE -ne 0) { throw "Elaboration failed: $simulationDir\$elaborateLog" }
        & (Join-Path $SimBin 'xsim.bat') $test.Snapshot -runall `
            -log ($test.Snapshot+'_xsim.log') *> $simulateLog
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $simulationDir\$simulateLog" }
        $console = [IO.File]::ReadAllText((Join-Path $simulationDir $simulateLog))
        if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
            [regex]::Matches($console,'(?m)'+$test.Pass).Count -ne 1) {
            throw "Differential regression failed: $simulationDir\$simulateLog"
        }
        Select-String -LiteralPath $simulateLog -Pattern '_CASE_PASS|_EQUIVALENCE_PASS' |
            ForEach-Object { $_.Line }
    }
} finally {
    Pop-Location
}
