param(
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$simulationDir=Join-Path $env:TEMP ('anlogic_color_target_modes_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources=@(
    (Join-Path $projectRoot 'user_source\hdl_source\isp\red_target_detect_96.v'),
    (Join-Path $projectRoot 'sim\tb_color_target_modes.sv'),
    (Join-Path $TdSimLib 'ph1p_logic_eram.v'),
    (Join-Path $TdSimLib 'ph1p_phy_gsr.v')
)
$sourceArgs=($sources | ForEach-Object {'{'+$_.Replace('\','/')+'}'}) -join ' '
$run=@"
onerror {quit -code 1 -force}
vlib work
vlog -sv +define+RED_MULTI_PORTABLE_RAM $sourceArgs
vsim -t ps work.tb_color_target_modes work.PH1P_PHY_GSR
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),$run,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if ($LASTEXITCODE -ne 0) { throw "Color target mode simulation failed: $simulationDir\console.log" }
    $console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    if ([regex]::Matches($console,'(?m)^# COLOR_TARGET_MODES_PASS').Count -ne 1) {
        throw "Color target mode pass marker missing: $simulationDir\console.log"
    }
    Select-String -LiteralPath console.log -Pattern 'COLOR_TARGET_MODES_PASS' |
        ForEach-Object {$_.Line -replace '^#\s*',''}
} finally { Pop-Location }
