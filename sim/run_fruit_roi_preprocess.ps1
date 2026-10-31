param(
    [string] $OutputDir='',
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
if(-not $OutputDir) {
    $OutputDir=Join-Path $env:TEMP ('anlogic_fruit_roi_preprocess_'+[guid]::NewGuid().ToString('N'))
}
$simulationDir=[IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $simulationDir -Force | Out-Null
$sources=@(
    'user_source/hdl_source/fruit_merged/handfixed_preprocess.v',
    'user_source/hdl_source/fruit_merged/handcnn_normalize.v',
    'user_source/hdl_source/fruit_merged/handfixed_background.v',
    'user_source/hdl_source/cnn/cnn_eram_byte_dp.v',
    'sim/reference/ph1p_logic_dram_asym_sim.v',
    'sim/reference/ph1p_logic_eram_sync_sim.v',
    'sim/tb_fruit_roi_preprocess.sv'
)
foreach($source in $sources) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $source) -Destination $simulationDir
}
$sourceNames=@($sources | ForEach-Object {Split-Path -Leaf $_})
$hashes=foreach($sourceName in $sourceNames) {
    [pscustomobject]@{
        File=$sourceName
        SHA256=(Get-FileHash -LiteralPath (Join-Path $simulationDir $sourceName) -Algorithm SHA256).Hash
    }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$compile=$sourceNames -join ' '
$script=@"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv $compile
vsim -onfinish exit -t ps work.tb_fruit_roi_preprocess
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $script,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    $console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    $cases=[regex]::Matches($console,'(?m)^\s*(?:#\s*)?FRUIT_ROI_PREPROCESS_CASE_PASS\b.*$')
    $passes=[regex]::Matches($console,'(?m)^\s*(?:#\s*)?FRUIT_ROI_PREPROCESS_PASS\b.*$')
    if($LASTEXITCODE -ne 0 -or
       $console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
       $cases.Count -ne 3 -or $passes.Count -ne 1) {
        throw "Fruit ROI preprocessing regression failed: $simulationDir/console.log"
    }
    @($cases)+@($passes) | ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
} finally {
    Pop-Location
}
