param(
    [ValidateSet('Portable', 'Vendor', 'Both')]
    [string] $Mode = 'Portable',
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sources = @(
    'user_source\hdl_source\isp\motion_target_detect_96.v',
    'user_source\hdl_source\isp\red_target_detect_96.v',
    'user_source\hdl_source\isp\target_detect_switch_96.v',
    'sim\tb_motion_target_detect_96.sv'
)
$simulationDir = Join-Path $env:TEMP ('anlogic_motion_target_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources = @()
foreach ($relative in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $destination
    $compiledSources += $destination
}
$topNames = @('tb_motion_target_detect_96', 'tb_target_detect_switch_96', 'tb_motion_full_resolution')
$passPatterns = @('MOTION_TARGET_DETECT_PASS', 'TARGET_DETECT_SWITCH_PASS', 'MOTION_FULL_RESOLUTION_PASS')
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    if ($Mode -eq 'Portable' -or $Mode -eq 'Both') {
        foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
            if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
                throw "XSim tool is missing: $tool"
            }
        }
        & (Join-Path $SimBin 'xvlog.bat') -sv -d MOTION_PORTABLE_RAM @compiledSources `
            -log xvlog.log *> portable_compile.log
        if ($LASTEXITCODE -ne 0) {
            throw "Motion compile failed; see $simulationDir\portable_compile.log"
        }
        for ($index = 0; $index -lt $topNames.Count; $index++) {
            $topName = $topNames[$index]
            $snapshotName = "motion_$index"
            & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
                "work.$topName" -s $snapshotName -log "xelab_$index.log" *> "portable_elaborate_$index.log"
            if ($LASTEXITCODE -ne 0) {
                throw "Motion elaboration failed; see $simulationDir\portable_elaborate_$index.log"
            }
            & (Join-Path $SimBin 'xsim.bat') $snapshotName -runall `
                -log "xsim_$index.log" *> "portable_simulate_$index.log"
            if ($LASTEXITCODE -ne 0) {
                throw "Motion simulation failed; see $simulationDir\portable_simulate_$index.log"
            }
            $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir "portable_simulate_$index.log"))
            if ($console -match '(?im)^\s*(?:#\s*)?(?:Fatal:|\*\*\s+(?:Fatal|Error)\b)' -or
                $console -notmatch "(?m)^$($passPatterns[$index])\b") {
                throw "Motion portable case failed; see $simulationDir\portable_simulate_$index.log"
            }
            [regex]::Match($console, "(?m)^$($passPatterns[$index]).*$").Value
        }
    }
    if ($Mode -eq 'Vendor' -or $Mode -eq 'Both') {
        foreach ($tool in @('vsim.exe', 'vlog.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
                throw "ModelSim tool is missing: $tool"
            }
        }
        $vendorSources = @($compiledSources)
        foreach ($primitive in @('ph1p_logic_eram.v', 'ph1p_phy_gsr.v')) {
            $destination = Join-Path $simulationDir $primitive
            Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $destination
            $vendorSources += $destination
        }
        $tclSources = ($vendorSources | ForEach-Object { '{' + $_.Replace('\', '/') + '}' }) -join ' '
        $runScript = @"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $tclSources
foreach top {tb_motion_target_detect_96 tb_target_detect_switch_96 tb_motion_full_resolution} {
    vsim -t ps work.`$top work.PH1P_PHY_GSR
    onfinish stop
    run -all
    quit -sim
}
quit -code 0 -force
"@
        $runPath = Join-Path $simulationDir 'vendor_run.do'
        [System.IO.File]::WriteAllText($runPath, $runScript, [System.Text.UTF8Encoding]::new($false))
        & (Join-Path $ModelSimBin 'vsim.exe') -c -do vendor_run.do -l vendor_transcript.log *> vendor_console.log
        if ($LASTEXITCODE -ne 0) {
            throw "Motion vendor simulation failed; see $simulationDir\vendor_console.log"
        }
        $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'vendor_console.log'))
        if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b') {
            throw "Motion vendor simulation reported a fatal/error; see $simulationDir\vendor_console.log"
        }
        foreach ($pattern in $passPatterns) {
            $matches = [regex]::Matches($console, "(?m)^\s*(?:#\s*)?$pattern\b.*$")
            if ($matches.Count -ne 1) {
                throw "Incomplete vendor motion coverage; see $simulationDir\vendor_console.log"
            }
            $matches[0].Value.Trim() -replace '^#\s*', ''
        }
    }
    Write-Output "MOTION_REGRESSION_PASS mode=$Mode"
} finally {
    Pop-Location
}
