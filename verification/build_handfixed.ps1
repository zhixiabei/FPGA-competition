param(
    [string]$Python='E:/Python314/python.exe',
    [string]$Td='E:/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe',
    [switch]$Fruit
)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskOutput=Join-Path $taskRoot 'build/gesture/td'
if($Fruit){$taskOutput=Join-Path $taskRoot 'build/fruit/td'}
$taskPreviousProject=$env:HANDFIXED_BUILD_PROJECT
$taskPreviousFruit=$env:FRUITFIXED_BUILD
try {
    $env:HANDFIXED_BUILD_PROJECT=$taskOutput
    $env:FRUITFIXED_BUILD=if($Fruit){'1'}else{'0'}
    $taskFlow=if($Fruit){'build_fruit128.tcl'}else{'build_handfixed_background.tcl'}
    & $Td (Join-Path $PSScriptRoot $taskFlow)
    if($LASTEXITCODE -ne 0){throw 'TD build failed; existing published firmware preserved'}
} finally {
    $env:HANDFIXED_BUILD_PROJECT=$taskPreviousProject
    $env:FRUITFIXED_BUILD=$taskPreviousFruit
}
$taskBit=Join-Path $taskRoot 'td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit'
if($Fruit){$taskBit=Join-Path $taskRoot 'td_project/anlogic_edge_osd_Runs/best_result/fruitfixed_candidate.bit'}
if(-not (Test-Path -LiteralPath $taskBit)){throw 'Bitstream not generated'}
Write-Output "New bitstream: $taskBit"
Write-Output 'Existing published bitstream is preserved. Review timing reports before programming.'
