param(
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $OutputDir='',
    [string] $TdSimLib='D:\TD\sim_release\ph1p'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
if(-not $OutputDir) {
    $OutputDir=Join-Path $env:TEMP ('anlogic_fruit_roi_system_'+[guid]::NewGuid().ToString('N'))
}
$simulationDir=[IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $simulationDir -Force | Out-Null
# Compile the integrated production fruit_merged files directly, never an
# earlier exported candidate project or the historical handfixed system.
$sources=@(
    'user_source/hdl_source/fruit_merged/fruitfixed_system.v',
    'user_source/hdl_source/fruit_merged/handfixed_key_control.v',
    'user_source/hdl_source/fruit_merged/handfixed_config.v',
    'user_source/hdl_source/handcnn/handcnn_snapshot.v',
    'user_source/hdl_source/fruit_merged/handfixed_preprocess.v',
    'user_source/hdl_source/fruit_merged/handcnn_normalize.v',
    'user_source/hdl_source/fruit_merged/handfixed_program.v',
    'user_source/hdl_source/fruit_merged/fruitcnn128_core.v',
    'user_source/hdl_source/fruit_merged/fruitfixed_decode.v',
    'user_source/hdl_source/fruit_merged/handcnn_confidence.v',
    'user_source/hdl_source/fruit_merged/fruitfixed_result_filter.v',
    'user_source/hdl_source/fruit_merged/handfixed_background.v',
    'user_source/hdl_source/cnn/cnn_eram_byte_dp.v',
    'user_source/hdl_source/resnet18/resnet18_uart.v',
    'user_source/hdl_source/resnet18/resnet18_weight_loader.v',
    'user_source/hdl_source/flash/flash_status_uart.v',
    'user_source/hdl_source/flash/fruit_flash_boot.v',
    'user_source/hdl_source/flash/spi_flash_reader.v',
    'user_source/hdl_source/flash/spi_flash_byte.v',
    (Join-Path $TdSimLib 'ph1p_logic_eram.v'),
    (Join-Path $TdSimLib 'ph1p_logic_dram.v'),
    (Join-Path $TdSimLib 'ph1p_phy_gsr.v'),
    'sim/resnet18_dsp_reference.sv',
    'sim/tb_fruit_roi_system.sv'
)
foreach($source in $sources) {
    $sourcePath=if([IO.Path]::IsPathRooted($source)) {$source} else {Join-Path $projectRoot $source}
    Copy-Item -LiteralPath $sourcePath -Destination $simulationDir
}
$sourceNames=@($sources | ForEach-Object {Split-Path -Leaf $_})
$hashes=foreach($source in $sources) {
    $sourceName=Split-Path -Leaf $source
    [pscustomobject]@{
        Source=$source
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
vsim -onfinish exit -t ps work.tb_fruit_roi_system work.PH1P_PHY_GSR
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
    if($LASTEXITCODE -ne 0 -or
       $console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
       $console -notmatch '(?m)^\s*(?:#\s*)?FRUIT_ROI_SYSTEM_PASS\b') {
        throw "Fruit ROI system regression failed: $simulationDir/console.log"
    }
    [regex]::Matches($console,'(?m)^\s*(?:#\s*)?FRUIT_ROI_SYSTEM_PASS\b.*$') |
        ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
} finally {
    Pop-Location
}
