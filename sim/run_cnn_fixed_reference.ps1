param(
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p',
    [string] $Python = 'python',
    [string] $VectorDirectory = '',
    [string] $WorkDirectory = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot

if (-not $VectorDirectory) {
    $VectorDirectory = Join-Path $root 'tmp\cnn_fixed_vectors'
}
if (-not $WorkDirectory) {
    $WorkDirectory = Join-Path $root ('tmp\cnn_fixed_reference_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
$VectorDirectory = [IO.Path]::GetFullPath($VectorDirectory)
$WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)
$generator = Join-Path $PSScriptRoot 'cnn_fixed_reference.py'
& $Python $generator --output-dir $VectorDirectory | Out-Null
if ($LASTEXITCODE -ne 0) { throw "reference generation failed: $LASTEXITCODE" }
"Independent reference vectors: $VectorDirectory"

$sources = @(
    (Join-Path $PSScriptRoot 'tb_cnn_fixed_reference.sv'),
    (Join-Path $root 'user_source\hdl_source\cnn\cnn_infer_32.v'),
    (Join-Path $root 'user_source\hdl_source\cnn\cnn_eram_byte_dp.v'),
    (Join-Path $root 'user_source\hdl_source\cnn\cnn_weights.v'),
    (Join-Path $TdSimLib 'ph1p_logic_eram.v'),
    (Join-Path $TdSimLib 'ph1p_phy_gsr.v')
)
foreach ($source in $sources) {
    if (-not (Test-Path -LiteralPath $source)) { throw "missing source: $source" }
}
foreach ($tool in @('vlib.exe', 'vlog.exe', 'vsim.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool))) {
        throw "missing simulator: $ModelSimBin\$tool"
    }
}
New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
Push-Location $WorkDirectory
try {
    "work dir: $WorkDirectory"
    & "$ModelSimBin\vlib.exe" work
    if ($LASTEXITCODE -ne 0) { throw "vlib failed: $LASTEXITCODE" }
    & "$ModelSimBin\vlog.exe" -sv -work work @sources 2>&1 |
        Tee-Object -FilePath compile.log | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Get-Content compile.log -Tail 30
        throw "vlog failed: $LASTEXITCODE"
    }
    $vectorsArg = '+VECTORS=' + $VectorDirectory.Replace('\', '/')
    & "$ModelSimBin\vsim.exe" -c -l simulation.log work.tb_cnn_fixed_reference work.PH1P_PHY_GSR `
        $vectorsArg -do 'run -all; quit -f' 2>&1 |
        Tee-Object -FilePath console.log | Out-Null
    $simExit = $LASTEXITCODE
    Get-Content console.log -Tail 30
    $transcript = Get-Content console.log -Raw
    if ($simExit -ne 0 -or $transcript -notmatch 'CNN_FIXED_REFERENCE_PASS' -or
        $transcript -match 'CNN_FIXED_REFERENCE_FAIL') {
        throw "CNN vendor/reference regression failed; see $WorkDirectory\simulation.log"
    }
    "CNN vendor/reference regression passed. Log: $WorkDirectory\simulation.log"
}
finally {
    Pop-Location
}
