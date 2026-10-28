param(
    [string] $SimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p',
    [string] $OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('vlib.exe', 'vlog.exe', 'vsim.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "Missing ModelSim tool: $tool"
    }
}
if (-not $OutputDirectory) {
    $runName = 'dsp_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    $OutputDirectory = Join-Path $projectRoot ('build\fruit_timing\verification\' + $runName)
}
$simulationDir = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $simulationDir) {
    throw "Choose a new output directory: $simulationDir"
}
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    (Join-Path $TdSimLib 'ph1p_phy_gsr.v'),
    (Join-Path $TdSimLib 'ph1p_phy_dspsiou_v2.v'),
    (Join-Path $TdSimLib 'ph1p_phy_dspmult_v2.v'),
    (Join-Path $TdSimLib 'ph1p_phy_dsptadd.v'),
    (Join-Path $projectRoot 'user_source\hdl_source\resnet\resnet_ph1p_dsp.v'),
    (Join-Path $PSScriptRoot 'tb_fruit_dsp_timing.sv')
)
$sourceNames = foreach ($source in $sources) {
    Copy-Item -LiteralPath $source -Destination $simulationDir
    Split-Path -Leaf $source
}
$hashes = foreach ($name in $sourceNames) {
    [pscustomobject]@{
        File = $name
        SHA256 = (Get-FileHash -LiteralPath (Join-Path $simulationDir $name) -Algorithm SHA256).Hash
    }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'vlib.exe') work *> vlib_console.log
    if ($LASTEXITCODE -ne 0) { throw "vlib failed: $simulationDir\vlib_console.log" }
    & (Join-Path $SimBin 'vlog.exe') -work work -sv @sourceNames *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $simulationDir\compile_console.log" }
    $simulationCommands = 'onerror {quit -code 1 -force}; onbreak {quit -code 1 -force}; run -all; quit -code 0 -force'
    & (Join-Path $SimBin 'vsim.exe') -c -onfinish exit -t ps `
        work.tb_fruit_dsp_timing work.PH1P_PHY_GSR `
        -do $simulationCommands *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $simulationDir\simulate_console.log" }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match 'FRUIT_DSP_TIMING_FAIL|(?im)^\s*#?\s*\*\*\s*(?:Fatal|Error)' -or
        [regex]::Matches($console, '(?m)^#?\s*FRUIT_DSP_TIMING_PASS\b').Count -ne 1) {
        throw "DSP timing regression did not pass: $simulationDir\simulate_console.log"
    }
    Select-String -LiteralPath simulate_console.log -Pattern 'FRUIT_DSP_TIMING_PASS' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
