param(
    [ValidateSet('Portable', 'Vendor', 'Both')]
    [string] $Mode = 'Both',
    [int] $Width = 64,
    [int] $Height = 48,
    [ValidateRange(1, 4)]
    [int] $ColorCount = 4,
    [int] $TimeoutSeconds = 180,
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Width -lt 48 -or $Height -lt 32 -or $Width % 4 -ne 0) {
    throw 'Mask test patterns require Width >= 48, Height >= 32 and Width divisible by four.'
}
if ($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$simulationDir = Join-Path $env:TEMP ('anlogic_color_mask_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    'user_source\hdl_source\isp\red_target_detect_96.v',
    'user_source\hdl_source\isp\motion_target_detect_96.v',
    'user_source\hdl_source\isp\target_detect_switch_96.v',
    'user_source\hdl_source\isp\rgb_edge_switch_96.v',
    'user_source\hdl_source\isp\scharr_edge_detect_96.v',
    'sim\tb_color_mask_pipeline.sv'
)
foreach ($source in $sources) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $source) `
        -Destination (Join-Path $simulationDir (Split-Path -Leaf $source))
}
$sourceHashes = Get-ChildItem -LiteralPath $simulationDir -File | ForEach-Object {
    [pscustomobject]@{
        File = $_.Name
        SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
}
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$rtlSources = ($sources | ForEach-Object { Split-Path -Leaf $_ }) -join ' '
Write-Output "Simulation output: $simulationDir"
foreach ($variant in $(if ($Mode -eq 'Both') { @('Portable', 'Vendor') } else { @($Mode) })) {
    $stem = $variant.ToLowerInvariant()
    $defines = if ($variant -eq 'Portable') {
        '+define+RED_MULTI_PORTABLE_RAM+MOTION_PORTABLE_RAM+SCHARR_PORTABLE_RAM'
    } else { '' }
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
vlog -sv $defines $rtlSources $vendorSources
vsim -t ps -gW=$Width -gH=$Height -gCOLOR_COUNT=$ColorCount work.tb_color_mask_pipeline $vendorTop
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
        throw "$variant color mask simulation timed out; see $consolePath"
    }
    $process.WaitForExit()
    $console = [IO.File]::ReadAllText($consolePath) + [IO.File]::ReadAllText($errorPath)
    $failurePattern = '(?im)^\s*(?:#\s*)?(?:\*\*\s*(?:Fatal|Error)\b|(?:Fatal|ERROR):)'
    $passPattern = '(?m)^\s*(?:#\s*)?COLOR_MASK_PIPELINE_PASS\b.*$'
    $framePattern = '(?m)^\s*(?:#\s*)?COLOR_MASK_FRAME_PASS\b'
    if ($process.ExitCode -ne 0 -or $console -match $failurePattern -or
        [regex]::Matches($console, $passPattern).Count -ne 1 -or
        [regex]::Matches($console, $framePattern).Count -ne 4*$ColorCount) {
        throw "$variant color mask simulation failed; see $consolePath"
    }
    [regex]::Match($console, $passPattern).Value.Trim() -replace '^#\s*', ''
}
Write-Output "COLOR_MASK_REGRESSION_PASS mode=$Mode"
