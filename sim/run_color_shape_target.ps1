param(
    [ValidateSet('Portable', 'Vendor', 'Both')]
    [string] $Mode = 'Portable',
    [int] $Width = 320,
    [int] $Height = 240,
    [int] $TimeoutSeconds = 180,
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Width -lt 288 -or $Height -lt 224 -or $Width % 4 -ne 0) {
    throw 'Shape test patterns require Width >= 288, Height >= 224 and Width divisible by four.'
}
if ($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$simulationDir = Join-Path $env:TEMP ('anlogic_color_shape_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'user_source\hdl_source\isp\red_target_detect_96.v') `
    -Destination (Join-Path $simulationDir 'red_target_detect_96.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_color_shape_target.sv') `
    -Destination (Join-Path $simulationDir 'tb_color_shape_target.sv')
$sourceHashes=foreach($snapshot in @('red_target_detect_96.v','tb_color_shape_target.sv')) {
    [pscustomobject]@{
        File=$snapshot
        SHA256=(Get-FileHash -LiteralPath (Join-Path $simulationDir $snapshot) -Algorithm SHA256).Hash
    }
}
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
$variants = if ($Mode -eq 'Both') { @('Portable', 'Vendor') } else { @($Mode) }
foreach ($variant in $variants) {
    $stem = $variant.ToLowerInvariant()
    $compileOptions = if ($variant -eq 'Portable') { '+define+RED_MULTI_PORTABLE_RAM' } else { '' }
    $vendorSources = ''
    $vendorTop = ''
    if ($variant -eq 'Vendor') {
        foreach ($primitive in @('ph1p_logic_eram.v', 'ph1p_phy_gsr.v')) {
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
vlog -sv $compileOptions red_target_detect_96.v tb_color_shape_target.sv $vendorSources
vsim -t ps -gW=$Width -gH=$Height work.tb_color_shape_target $vendorTop
run -all
quit -code 0 -force
"@
    $scriptPath = Join-Path $simulationDir ($stem + '_run.do')
    [IO.File]::WriteAllText($scriptPath, $runScript, [Text.UTF8Encoding]::new($false))
    $consolePath = Join-Path $simulationDir ($stem + '_console.log')
    $errorPath = Join-Path $simulationDir ($stem + '_stderr.log')
    $arguments = '-c -do ' + $stem + '_run.do -l ' + $stem + '_transcript.log'
    $process = Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
        -ArgumentList $arguments -WorkingDirectory $simulationDir -WindowStyle Hidden `
        -RedirectStandardOutput $consolePath -RedirectStandardError $errorPath -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        throw "$variant shape simulation timed out; see $consolePath"
    }
    $process.WaitForExit()
    $process.Refresh()
    if ($process.ExitCode -ne 0) {
        throw "$variant shape simulation failed with exit $($process.ExitCode); see $consolePath"
    }
    $console = [IO.File]::ReadAllText($consolePath) + [IO.File]::ReadAllText($errorPath)
    $failurePattern = '(?im)^\s*(?:#\s*)?(?:\*\*\s*(?:Fatal|Error)\b|(?:Fatal|ERROR):)'
    $passPattern = '(?m)^\s*(?:#\s*)?COLOR_SHAPE_TARGET_PASS\b.*$'
    $noisePattern = '(?m)^\s*(?:#\s*)?COLOR_SHAPE_NOISY_CASE_PASS\b'
    if ($console -match $failurePattern -or
        [regex]::Matches($console, $passPattern).Count -ne 1 -or
        [regex]::Matches($console, $noisePattern).Count -ne 30) {
        throw "$variant shape simulation failed or pass marker is missing; see $consolePath"
    }
    ([regex]::Match($console, $passPattern).Value.Trim() -replace '^#\s*', '')
}
Write-Output "COLOR_SHAPE_REGRESSION_PASS mode=$Mode"
