param(
    [ValidateSet('Portable', 'Vendor', 'Both')]
    [string] $Mode = 'Portable',
    [int] $Width = 256,
    [int] $Height = 128,
    [ValidateSet(8, 16)]
    [int] $CandidateSlots = 8,
    [ValidateSet(3, 4)]
    [int] $MaxTargets = 3,
    [switch] $RateOnly,
    [string] $RtlSource = '',
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Width -lt 256 -or $Height -lt 128 -or $Width % 4 -ne 0) {
    throw 'Test patterns require Width >= 256, Height >= 128 and Width divisible by four.'
}
if ($RateOnly -and ($Width -lt 1280 -or $Height -lt 720)) {
    throw 'RateOnly requires Width >= 1280 and Height >= 720.'
}
$rateOnlyValue = [int]$RateOnly.IsPresent
$projectRoot = Split-Path -Parent $PSScriptRoot
$simulationDir = Join-Path $env:TEMP ('anlogic_red_multi_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$source = if ($RtlSource) {
    [IO.Path]::GetFullPath($RtlSource)
} else {
    Join-Path $projectRoot 'user_source\hdl_source\isp\red_target_detect_96.v'
}
Copy-Item -LiteralPath $source `
    -Destination (Join-Path $simulationDir 'red_target_detect_96.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_red_multi_target.sv') `
    -Destination (Join-Path $simulationDir 'tb_red_multi_target.sv')
@('red_target_detect_96.v', 'tb_red_multi_target.sv') | ForEach-Object {
    [pscustomobject]@{
        File = $_
        SHA256 = (Get-FileHash -LiteralPath (Join-Path $simulationDir $_) -Algorithm SHA256).Hash
    }
} | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
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
            -generic_top ('"CANDIDATE_SLOTS=' + $CandidateSlots + '"') `
            -generic_top ('"MAX_TARGETS=' + $MaxTargets + '"') `
            -generic_top ('"RATE_ONLY=' + $rateOnlyValue + '"') `
            work.tb_red_multi_target -s red_multi -log xelab.log *> portable_elaborate.log
        if ($LASTEXITCODE -ne 0) { throw "Elaboration failed; see $simulationDir\portable_elaborate.log" }
        & (Join-Path $SimBin 'xsim.bat') red_multi -runall -log xsim.log *> portable_simulate.log
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed; see $simulationDir\portable_simulate.log" }
        $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'portable_simulate.log'))
        if ($console -match '(?im)^\s*(?:Fatal:|\*\*\s+(?:Fatal|Error)\b)' -or
            $console -notmatch '(?m)^RED_MULTI_TARGET_PASS\b') {
            throw "Portable test failed; see $simulationDir\portable_simulate.log"
        }
        if ($RateOnly) {
            [regex]::Matches($console, '(?m)^RED_MULTI_FRAME_PROCESSING.*$') |
                ForEach-Object { $_.Value }
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
vsim -t ps -gW=TEST_WIDTH -gH=TEST_HEIGHT -gCANDIDATE_SLOTS=TEST_CANDIDATES -gMAX_TARGETS=TEST_TARGETS -gRATE_ONLY=TEST_RATE_ONLY work.tb_red_multi_target work.PH1P_PHY_GSR
run -all
quit -code 0 -force
'@
        $runScript = $runScript.Replace('TEST_WIDTH', [string]$Width).Replace('TEST_HEIGHT', [string]$Height)
        $runScript = $runScript.Replace('TEST_CANDIDATES', [string]$CandidateSlots).Replace('TEST_TARGETS', [string]$MaxTargets)
        $runScript = $runScript.Replace('TEST_RATE_ONLY', [string]$rateOnlyValue)
        [System.IO.File]::WriteAllText((Join-Path $simulationDir 'vendor_run.do'), `
            $runScript, [System.Text.UTF8Encoding]::new($false))
        & (Join-Path $ModelSimBin 'vsim.exe') -c -do vendor_run.do -l vendor_transcript.log *> vendor_console.log
        if ($LASTEXITCODE -ne 0) { throw "Vendor simulation failed; see $simulationDir\vendor_console.log" }
        $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'vendor_console.log'))
        if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
            $console -notmatch '(?m)^\s*(?:#\s*)?RED_MULTI_TARGET_PASS\b') {
            throw "Vendor test failed; see $simulationDir\vendor_console.log"
        }
        if ($RateOnly) {
            [regex]::Matches($console, '(?m)^\s*(?:#\s*)?RED_MULTI_FRAME_PROCESSING.*$') |
                ForEach-Object { $_.Value.Trim() -replace '^#\s*', '' }
        }
        [regex]::Match($console, '(?m)^\s*(?:#\s*)?RED_MULTI_TARGET_PASS.*$').Value.Trim() -replace '^#\s*', ''
    }
    Write-Output "RED_MULTI_REGRESSION_PASS mode=$Mode candidates=$CandidateSlots targets=$MaxTargets rate_only=$rateOnlyValue"
} finally {
    Pop-Location
}
