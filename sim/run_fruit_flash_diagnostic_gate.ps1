param(
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
$simulationDir=Join-Path $env:TEMP ('anlogic_flash_diagnostic_gate_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
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
    'user_source/hdl_source/cnn/cnn_eram_byte_dp.v',
    'user_source/hdl_source/resnet18/resnet18_uart.v',
    'user_source/hdl_source/resnet18/resnet18_weight_loader.v',
    'user_source/hdl_source/flash/flash_status_uart.v',
    'user_source/hdl_source/flash/fruit_flash_boot.v',
    'user_source/hdl_source/flash/spi_flash_reader.v',
    'user_source/hdl_source/flash/spi_flash_byte.v',
    'sim/reference/fruit_core_coefficient_ram_sim.v',
    'sim/reference/ph1p_logic_dram_asym_sim.v',
    'sim/resnet18_dsp_reference.sv',
    'sim/tb_fruit_flash_diagnostic_gate.sv'
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
onbreak {resume}
vlib work
vlog -sv $compile
vsim -t ps work.tb_fruit_flash_diagnostic_gate
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
       $console -notmatch '(?m)^\s*(?:#\s*)?FRUIT_FLASH_DIAGNOSTIC_GATE_PASS\b') {
        throw "Flash diagnostic gate regression failed: $simulationDir/console.log"
    }
    [regex]::Matches($console,'(?m)^\s*(?:#\s*)?FRUIT_FLASH_DIAGNOSTIC_GATE_PASS\b.*$') |
        ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
} finally {
    Pop-Location
}
