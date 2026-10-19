param(
    [ValidateSet('Portable', 'Vendor', 'Both')]
    [string] $Mode = 'Both',
    [int] $TimeoutSeconds = 300,
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
foreach ($tool in @('vsim.exe','vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$simulationDir = Join-Path $env:TEMP ('anlogic_shape_stability_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    'user_source\hdl_source\isp\red_target_detect_96.v',
    'user_source\hdl_source\isp\target_detect_switch_96.v',
    'user_source\hdl_source\isp\motion_target_detect_96.v',
    'sim\tb_color_shape_stability.sv'
)
foreach ($source in $sources) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $source) `
        -Destination (Join-Path $simulationDir (Split-Path -Leaf $source))
}
$sourceHashes = foreach ($source in $sources) {
    $name = Split-Path -Leaf $source
    [pscustomobject]@{
        File=$name
        SHA256=(Get-FileHash -LiteralPath (Join-Path $simulationDir $name) -Algorithm SHA256).Hash
    }
}
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
$variants = if ($Mode -eq 'Both') { @('Portable','Vendor') } else { @($Mode) }
foreach ($variant in $variants) {
    $stem = $variant.ToLowerInvariant()
    $compileOptions = if ($variant -eq 'Portable') {
        '+define+RED_MULTI_PORTABLE_RAM +define+MOTION_PORTABLE_RAM'
    } else { '' }
    $vendorSources = ''
    $vendorTop = ''
    if ($variant -eq 'Vendor') {
        foreach ($primitive in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')) {
            Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) `
                -Destination (Join-Path $simulationDir $primitive)
        }
        $vendorSources = 'ph1p_logic_eram.v ph1p_phy_gsr.v'
        $vendorTop = 'work.PH1P_PHY_GSR'
    }
    $runScript = @"
onerror {quit -code 1 -force}
onbreak {resume}
if {[file exists work]} {vdel -all -lib work}
vlib work
vlog -sv $compileOptions red_target_detect_96.v target_detect_switch_96.v motion_target_detect_96.v tb_color_shape_stability.sv $vendorSources
vsim -t ps work.tb_color_shape_stability $vendorTop
run -all
quit -code 0 -force
"@
    [IO.File]::WriteAllText((Join-Path $simulationDir ($stem + '_run.do')),
        $runScript,[Text.UTF8Encoding]::new($false))
    $consolePath = Join-Path $simulationDir ($stem + '_console.log')
    $errorPath = Join-Path $simulationDir ($stem + '_stderr.log')
    $process = Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
        -ArgumentList ('-c -do ' + $stem + '_run.do -l ' + $stem + '_transcript.log') `
        -WorkingDirectory $simulationDir -WindowStyle Hidden `
        -RedirectStandardOutput $consolePath -RedirectStandardError $errorPath -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        throw "$variant temporal simulation timed out; see $consolePath"
    }
    $process.WaitForExit()
    $process.Refresh()
    $console = [IO.File]::ReadAllText($consolePath) + [IO.File]::ReadAllText($errorPath)
    $passPattern = '(?m)^\s*(?:#\s*)?COLOR_SHAPE_STABILITY_PASS\b.*$'
    $failurePattern = '(?im)^\s*(?:#\s*)?(?:\*\*\s*(?:Fatal|Error)\b|(?:Fatal|ERROR):)'
    if ($process.ExitCode -ne 0 -or $console -match $failurePattern -or
        [regex]::Matches($console,$passPattern).Count -ne 1) {
        throw "$variant temporal simulation failed; see $consolePath"
    }
    ([regex]::Match($console,$passPattern).Value.Trim() -replace '^#\s*','')
}
Write-Output "COLOR_SHAPE_STABILITY_REGRESSION_PASS mode=$Mode"
