param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [int] $Width = 64,
    [int] $Height = 48,
    [ValidateSet('XSim', 'Portable', 'Vendor', 'Both')]
    [string] $Mode = 'XSim',
    [int] $TimeoutSeconds = 180,
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $projectRoot 'user_source\hdl_source\isp\red_target_detect_96.v'
if ($Width -lt 32 -or $Height -lt 32 -or $Width % 4 -ne 0) {
    throw 'Lighting test patterns require Width >= 32, Height >= 32 and Width divisible by four.'
}
if ($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
if ($Mode -eq 'XSim') {
    foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
            throw "XSim tool is missing: $tool"
        }
    }
} else {
    foreach ($tool in @('vsim.exe', 'vlog.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
            throw "ModelSim tool is missing: $tool"
        }
    }
}

$simulationDir = Join-Path $env:TEMP ('anlogic_red_lighting_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $simulationDir 'red_target_detect_96.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_red_target_detect_96.sv') `
    -Destination (Join-Path $simulationDir 'tb_red_target_detect_96.sv')
$sourceHashes = Get-ChildItem -LiteralPath $simulationDir -File | ForEach-Object {
    [pscustomobject]@{
        File = $_.Name
        SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
}
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
@{
    Mode = $Mode
    Width = $Width
    Height = $Height
    RedPolicy = 'red only: abs(G-B)/(R-min(G,B)) <= 1/5; brightness/delta/saturation unchanged'
    Oracle = 'scalar integer channels plus literal hue/saturation boundary witnesses'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $simulationDir 'manifest.json') -Encoding UTF8
Write-Output "Simulation output: $simulationDir"
if ($Mode -ne 'XSim') {
    foreach ($variant in $(if ($Mode -eq 'Both') { @('Portable', 'Vendor') } else { @($Mode) })) {
        $stem = $variant.ToLowerInvariant()
        $defines = if ($variant -eq 'Portable') { '+define+RED_MULTI_PORTABLE_RAM' } else { '' }
        $vendorSources = ''
        $vendorTop = ''
        if ($variant -eq 'Vendor') {
            foreach ($primitive in @('ph1p_logic_eram.v', 'ph1p_logic_dram.v', 'ph1p_phy_gsr.v')) {
                Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) `
                    -Destination (Join-Path $simulationDir $primitive)
            }
            $vendorSources = 'ph1p_logic_eram.v ph1p_logic_dram.v ph1p_phy_gsr.v'
            $vendorTop = 'work.PH1P_PHY_GSR'
        }
        $script = @"
onerror {quit -code 1 -force}
onbreak {resume}
if {[file exists work]} {vdel -all -lib work}
vlib work
vlog -sv $defines red_target_detect_96.v tb_red_target_detect_96.sv $vendorSources
vsim -t ps -gW=$Width -gH=$Height work.tb_red_target_detect_96 $vendorTop
run -all
quit -code 0 -force
"@
        [IO.File]::WriteAllText((Join-Path $simulationDir ($stem + '.do')),
            $script, [Text.UTF8Encoding]::new($false))
        $consolePath = Join-Path $simulationDir ($stem + '_console.log')
        $errorPath = Join-Path $simulationDir ($stem + '_stderr.log')
        $process = Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
            -ArgumentList "-c -do $stem.do -l ${stem}_transcript.log" `
            -WorkingDirectory $simulationDir -WindowStyle Hidden `
            -RedirectStandardOutput $consolePath -RedirectStandardError $errorPath -PassThru
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
            throw "$variant lighting simulation timed out; see $consolePath"
        }
        $process.WaitForExit()
        $console = [IO.File]::ReadAllText($consolePath) + [IO.File]::ReadAllText($errorPath)
        $failurePattern = '(?im)^\s*(?:#\s*)?(?:\*\*\s*(?:Fatal|Error)\b|(?:Fatal|ERROR):)'
        $passPattern = '(?m)^\s*(?:#\s*)?RED_TARGET_LIGHTING_PASS\b.*$'
        if ($process.ExitCode -ne 0 -or $console -match $failurePattern -or
            [regex]::Matches($console, $passPattern).Count -ne 1) {
            throw "$variant lighting simulation failed; see $consolePath"
        }
        [regex]::Match($console, $passPattern).Value.Trim() -replace '^#\s*', ''
    }
    Write-Output "RED_TARGET_LIGHTING_REGRESSION_PASS mode=$Mode"
    return
}
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv -d RED_MULTI_PORTABLE_RAM `
        red_target_detect_96.v tb_red_target_detect_96.sv `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim compile failed; see compile_console.log' }

    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        -generic_top ('"W=' + $Width + '"') -generic_top ('"H=' + $Height + '"') `
        work.tb_red_target_detect_96 -s red_target_lighting -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim elaboration failed; see elaborate_console.log' }

    & (Join-Path $SimBin 'xsim.bat') red_target_lighting -runall -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw 'XSim simulation failed; see simulate_console.log' }
    $pass = Select-String -LiteralPath simulate_console.log -Pattern '^RED_TARGET_LIGHTING_PASS'
    if (-not $pass) { throw 'Red target lighting test did not pass; see simulate_console.log' }
    $pass.Line
} finally {
    Pop-Location
}
