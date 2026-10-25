param(
    [ValidateSet('Portable', 'Vendor', 'Both')]
    [string] $Mode = 'Portable',
    [int] $Width = 256,
    [int] $Height = 128,
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Width -lt 256 -or $Height -lt 128 -or $Width % 4 -ne 0) {
    throw 'Test patterns require Width >= 256, Height >= 128 and Width divisible by four.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$simulationDir = Join-Path $env:TEMP ('anlogic_red_multi_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'user_source\hdl_source\isp\red_target_detect_96.v') `
    -Destination (Join-Path $simulationDir 'red_target_detect_96.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_red_multi_target.sv') `
    -Destination (Join-Path $simulationDir 'tb_red_multi_target.sv')
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    if ($Mode -eq 'Portable' -or $Mode -eq 'Both') {
        foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
            if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
                throw "XSim tool is missing: $tool"
            }
        }
        & (Join-Path $SimBin 'xvlog.bat') -sv -d RED_MULTI_PORTABLE_RAM `
            red_target_detect_96.v tb_red_multi_target.sv -log xvlog.log *> portable_compile.log
        if ($LASTEXITCODE -ne 0) { throw "Compile failed; see $simulationDir\portable_compile.log" }
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            -generic_top ('"W=' + $Width + '"') -generic_top ('"H=' + $Height + '"') `
            work.tb_red_multi_target -s red_multi -log xelab.log *> portable_elaborate.log
        if ($LASTEXITCODE -ne 0) { throw "Elaboration failed; see $simulationDir\portable_elaborate.log" }
        & (Join-Path $SimBin 'xsim.bat') red_multi -runall -log xsim.log *> portable_simulate.log
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed; see $simulationDir\portable_simulate.log" }
        $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'portable_simulate.log'))
        if ($console -match '(?im)^\s*(?:Fatal:|\*\*\s+(?:Fatal|Error)\b)' -or
            $console -notmatch '(?m)^RED_MULTI_TARGET_PASS\b') {
            throw "Portable test failed; see $simulationDir\portable_simulate.log"
        }
        [regex]::Match($console, '(?m)^RED_MULTI_TARGET_PASS.*$').Value
    }
    if ($Mode -eq 'Vendor' -or $Mode -eq 'Both') {
        foreach ($tool in @('vsim.exe', 'vlog.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
                throw "ModelSim tool is missing: $tool"
            }
        }
        foreach ($primitive in @('ph1p_logic_eram.v', 'ph1p_phy_gsr.v')) {
            Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination (Join-Path $simulationDir $primitive)
        }
        $runScript = @'
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv red_target_detect_96.v tb_red_multi_target.sv ph1p_logic_eram.v ph1p_phy_gsr.v
vsim -t ps -gW=TEST_WIDTH -gH=TEST_HEIGHT work.tb_red_multi_target work.PH1P_PHY_GSR
run -all
quit -code 0 -force
'@
        $runScript = $runScript.Replace('TEST_WIDTH', [string]$Width).Replace('TEST_HEIGHT', [string]$Height)
        [System.IO.File]::WriteAllText((Join-Path $simulationDir 'vendor_run.do'), `
            $runScript, [System.Text.UTF8Encoding]::new($false))
        & (Join-Path $ModelSimBin 'vsim.exe') -c -do vendor_run.do -l vendor_transcript.log *> vendor_console.log
        if ($LASTEXITCODE -ne 0) { throw "Vendor simulation failed; see $simulationDir\vendor_console.log" }
        $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'vendor_console.log'))
        if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
            $console -notmatch '(?m)^\s*(?:#\s*)?RED_MULTI_TARGET_PASS\b') {
            throw "Vendor test failed; see $simulationDir\vendor_console.log"
        }
        [regex]::Match($console, '(?m)^\s*(?:#\s*)?RED_MULTI_TARGET_PASS.*$').Value.Trim() -replace '^#\s*', ''
    }
    Write-Output "RED_MULTI_REGRESSION_PASS mode=$Mode"
} finally {
    Pop-Location
}
