param(
    [ValidateSet('Portable', 'Vendor', 'Both')]
    [string] $Mode = 'Portable',
    [ValidateSet(8, 16)]
    [int] $CandidateSlots = 8,
    [ValidateSet(3, 4)]
    [int] $MaxTargets = 3,
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$simulationDir = Join-Path $env:TEMP ('anlogic_red_switch_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    'user_source\hdl_source\isp\red_target_detect_96.v',
    'user_source\hdl_source\isp\motion_target_detect_96.v',
    'user_source\hdl_source\isp\target_detect_switch_96.v',
    'sim\tb_red_multi_switch.sv'
)
$names = @()
foreach ($relative in $sources) {
    $name = Split-Path -Leaf $relative
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination (Join-Path $simulationDir $name)
    $names += $name
}
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    if ($Mode -eq 'Portable' -or $Mode -eq 'Both') {
        & (Join-Path $SimBin 'xvlog.bat') -sv -d RED_MULTI_PORTABLE_RAM -d MOTION_PORTABLE_RAM `
            @names -log xvlog.log *> portable_compile.log
        if ($LASTEXITCODE -ne 0) { throw "Compile failed; see $simulationDir\portable_compile.log" }
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            -generic_top ('"CANDIDATE_SLOTS=' + $CandidateSlots + '"') `
            -generic_top ('"MAX_TARGETS=' + $MaxTargets + '"') `
            work.tb_red_multi_switch -s red_switch -log xelab.log *> portable_elaborate.log
        if ($LASTEXITCODE -ne 0) { throw "Elaboration failed; see $simulationDir\portable_elaborate.log" }
        & (Join-Path $SimBin 'xsim.bat') red_switch -runall -log xsim.log *> portable_simulate.log
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed; see $simulationDir\portable_simulate.log" }
        $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'portable_simulate.log'))
        if ($console -match '(?im)^\s*(?:Fatal:|\*\*\s+(?:Fatal|Error)\b)' -or
            $console -notmatch '(?m)^RED_MULTI_SWITCH_PASS\b') {
            throw "Portable test failed; see $simulationDir\portable_simulate.log"
        }
        [regex]::Match($console, '(?m)^RED_MULTI_SWITCH_PASS.*$').Value
    }
    if ($Mode -eq 'Vendor' -or $Mode -eq 'Both') {
        foreach ($primitive in @('ph1p_logic_eram.v', 'ph1p_phy_gsr.v')) {
            Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination (Join-Path $simulationDir $primitive)
        }
        $runScript = @'
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv red_target_detect_96.v motion_target_detect_96.v target_detect_switch_96.v tb_red_multi_switch.sv ph1p_logic_eram.v ph1p_phy_gsr.v
vsim -t ps -gCANDIDATE_SLOTS=TEST_CANDIDATES -gMAX_TARGETS=TEST_TARGETS work.tb_red_multi_switch work.PH1P_PHY_GSR
run -all
quit -code 0 -force
'@
        $runScript = $runScript.Replace('TEST_CANDIDATES', [string]$CandidateSlots).Replace('TEST_TARGETS', [string]$MaxTargets)
        [System.IO.File]::WriteAllText((Join-Path $simulationDir 'vendor_run.do'), `
            $runScript, [System.Text.UTF8Encoding]::new($false))
        & (Join-Path $ModelSimBin 'vsim.exe') -c -do vendor_run.do -l vendor_transcript.log *> vendor_console.log
        if ($LASTEXITCODE -ne 0) { throw "Vendor simulation failed; see $simulationDir\vendor_console.log" }
        $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'vendor_console.log'))
        if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
            $console -notmatch '(?m)^\s*(?:#\s*)?RED_MULTI_SWITCH_PASS\b') {
            throw "Vendor test failed; see $simulationDir\vendor_console.log"
        }
        [regex]::Match($console, '(?m)^\s*(?:#\s*)?RED_MULTI_SWITCH_PASS.*$').Value.Trim() -replace '^#\s*', ''
    }
    Write-Output "RED_MULTI_SWITCH_REGRESSION_PASS mode=$Mode candidates=$CandidateSlots targets=$MaxTargets"
} finally {
    Pop-Location
}
