param(
    [ValidateSet('Raw', 'Stable')]
    [string] $Pipeline = 'Stable',
    [ValidateSet('Portable', 'Vendor', 'Both')]
    [string] $Mode = 'Portable',
    [string] $DetectorSource = '',
    [string] $SwitchSource = '',
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p',
    [switch] $CheckBehavior
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $DetectorSource) {
    $DetectorSource = Join-Path $projectRoot 'user_source\hdl_source\isp\motion_target_detect_96.v'
}
if (-not $SwitchSource) {
    $SwitchSource = Join-Path $projectRoot 'user_source\hdl_source\isp\target_detect_switch_96.v'
}
$simulationDir = Join-Path $env:TEMP ('anlogic_motion_stability_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @($DetectorSource, (Join-Path $PSScriptRoot 'tb_motion_stability.sv'))
if ($Pipeline -eq 'Stable') {
    $sources += @($SwitchSource, (Join-Path $projectRoot 'user_source\hdl_source\isp\red_target_detect_96.v'))
}
$compiledSources = @()
foreach ($source in $sources) {
    $copy = Join-Path $simulationDir (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $copy
    $compiledSources += $copy
}
$stableParameter = [int] ($Pipeline -eq 'Stable')
$checkParameter = [int] $CheckBehavior.IsPresent
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    if ($Mode -eq 'Portable' -or $Mode -eq 'Both') {
        & (Join-Path $SimBin 'xvlog.bat') -sv -d MOTION_PORTABLE_RAM -d RED_MULTI_PORTABLE_RAM @compiledSources `
            -log xvlog.log *> portable_compile.log
        if ($LASTEXITCODE -ne 0) { throw "Stability compile failed; see $simulationDir\portable_compile.log" }
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            -generic_top "`"STABLE_PIPELINE=$stableParameter`"" `
            -generic_top "`"CHECK_BEHAVIOR=$checkParameter`"" `
            work.tb_motion_stability -s motion_stability -log xelab.log *> portable_elaborate.log
        if ($LASTEXITCODE -ne 0) { throw "Stability elaboration failed; see $simulationDir\portable_elaborate.log" }
        & (Join-Path $SimBin 'xsim.bat') motion_stability -runall -log xsim.log *> portable_simulate.log
        if ($LASTEXITCODE -ne 0) { throw "Stability simulation failed; see $simulationDir\portable_simulate.log" }
        $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'portable_simulate.log'))
        if ($console -match '(?im)^\s*(?:Fatal:|\*\*\s+(?:Fatal|Error)\b)' -or
            $console -notmatch '(?m)^MOTION_STABILITY_PASS\b') {
            throw "Stability portable case failed; see $simulationDir\portable_simulate.log"
        }
        [regex]::Matches($console, '(?m)^(?:STABILITY_SCENE|MOTION_STABILITY_PASS)\b.*$') |
            ForEach-Object { $_.Value }
        Copy-Item -LiteralPath motion_stability_frames.csv -Destination portable_frames.csv
    }
    if ($Mode -eq 'Vendor' -or $Mode -eq 'Both') {
        $vendorSources = @($compiledSources)
        foreach ($primitive in @('ph1p_logic_eram.v', 'ph1p_phy_gsr.v')) {
            $copy = Join-Path $simulationDir $primitive
            Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $copy
            $vendorSources += $copy
        }
        $tclSources = ($vendorSources | ForEach-Object { '{' + $_.Replace('\', '/') + '}' }) -join ' '
        $script = @"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $tclSources
vsim -t ps -gSTABLE_PIPELINE=$stableParameter -gCHECK_BEHAVIOR=$checkParameter work.tb_motion_stability work.PH1P_PHY_GSR
onfinish stop
run -all
quit -code 0 -force
"@
        [System.IO.File]::WriteAllText((Join-Path $simulationDir 'vendor_run.do'),
            $script, [System.Text.UTF8Encoding]::new($false))
        & (Join-Path $ModelSimBin 'vsim.exe') -c -do vendor_run.do -l vendor_transcript.log *> vendor_console.log
        if ($LASTEXITCODE -ne 0) { throw "Stability vendor simulation failed; see $simulationDir\vendor_console.log" }
        $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'vendor_console.log'))
        if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
            $console -notmatch '(?m)^\s*(?:#\s*)?MOTION_STABILITY_PASS\b') {
            throw "Stability vendor case failed; see $simulationDir\vendor_console.log"
        }
        [regex]::Matches($console, '(?m)^\s*(?:#\s*)?(?:STABILITY_SCENE|MOTION_STABILITY_PASS)\b.*$') |
            ForEach-Object { $_.Value.Trim() -replace '^#\s*', '' }
        Copy-Item -LiteralPath motion_stability_frames.csv -Destination vendor_frames.csv
    }
    Write-Output "MOTION_STABILITY_REGRESSION_PASS pipeline=$Pipeline mode=$Mode"
} finally {
    Pop-Location
}
