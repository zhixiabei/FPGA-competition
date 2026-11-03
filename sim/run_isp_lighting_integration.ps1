param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p',
    [switch] $Motion,
    [switch] $Emboss,
    [switch] $Cartoon,
    [switch] $Morph,
    [switch] $ScharrInverse,
    [switch] $Binary,
    [switch] $Erosion,
    [switch] $Dilation,
    [switch] $CloseMask,
    [switch] $AllModes,
    [switch] $HoldRelease
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$selectedModes=@(@($Emboss,$Cartoon,$Morph,$ScharrInverse,$Binary,$Erosion,$Dilation,$CloseMask) | Where-Object { $_ })
if ($selectedModes.Count -gt 1) { throw 'Choose one third-frame display mode.' }
if ($AllModes -and ($Motion -or $selectedModes.Count -ne 0)) {
    throw 'AllModes cannot be combined with an individual mode.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'user_source\hdl_source'
$sources = @('isp\isp_top.v','isp\lsc_raw10_4x.v','awb.v',
    'isp\ae_frame_stats_raw10_4x.v',
    'isp\rgb_edge_switch_96.v','isp\scharr_edge_detect_96.v',
    'isp\red_target_detect_96.v','isp\motion_target_detect_96.v',
    'isp\target_detect_switch_96.v','isp\data96_128\data96_128.v',
    'isp\data128_96\data128_96.v')
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_isp_lighting_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources=@()
foreach($relative in $sources) {
    $destination=Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination
    $compiledSources+=$destination
}
$testbench=Join-Path $simulationDir 'tb_isp_lighting_integration.sv'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_isp_lighting_integration.sv') -Destination $testbench
# Compile the vendor's unchanged, plaintext functional DRAM module.
$primitiveText = [System.IO.File]::ReadAllText((Join-Path $TdSimLib 'ph1p_logic_dram.v'))
$primitiveModule = [regex]::Match($primitiveText, '(?s)\A.*?\bendmodule\b')
if (-not $primitiveModule.Success -or
    -not $primitiveModule.Value.Contains('module PH1P_LOGIC_DRAM')) {
    throw 'TD distributed RAM functional model was not found'
}
$primitiveSource = Join-Path $simulationDir 'ph1p_logic_dram.v'
[System.IO.File]::WriteAllText($primitiveSource,
    $primitiveModule.Value + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
$compiledSources += $primitiveSource
foreach ($primitive in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')) {
    $destination=Join-Path $simulationDir $primitive
    Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $destination
    $compiledSources += $destination
}
$sourceHashes=foreach($snapshot in @($compiledSources)+@($testbench)) {
    [pscustomobject]@{
        File=(Split-Path -Leaf $snapshot)
        SHA256=(Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
    }
}
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv -d SCHARR_PORTABLE_RAM @compiledSources $testbench `
        -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'ISP integration compile failed; see compile_console.log' }
    $runs = @([pscustomobject]@{
        Name='isp_lighting'; Motion=$Motion; Emboss=$Emboss; Cartoon=$Cartoon
        Morph=$Morph; ScharrInverse=$ScharrInverse; Binary=$Binary
        Erosion=$Erosion; Dilation=$Dilation; CloseMask=$CloseMask
    })
    if ($AllModes) {
        $runs = foreach ($mode in @('Normal','Motion','Emboss','Cartoon','Morph',
                                   'ScharrInverse','Binary','Erosion','Dilation','CloseMask')) {
            [pscustomobject]@{
                Name=('isp_lighting_' + $mode.ToLowerInvariant())
                Motion=$mode -eq 'Motion'; Emboss=$mode -eq 'Emboss'
                Cartoon=$mode -eq 'Cartoon'; Morph=$mode -eq 'Morph'
                ScharrInverse=$mode -eq 'ScharrInverse'; Binary=$mode -eq 'Binary'
                Erosion=$mode -eq 'Erosion'; Dilation=$mode -eq 'Dilation'
                CloseMask=$mode -eq 'CloseMask'
            }
        }
    }
    foreach ($run in $runs) {
        $modeArgs=@()
        if ($HoldRelease) { $modeArgs+=@('-generic_top','"HOLD_RELEASE_TEST=1"') }
        if ($run.Motion) { $modeArgs+=@('-generic_top','"MOTION_MODE=1"') }
        if ($run.Emboss) { $modeArgs+=@('-generic_top','"EMBOSS_MODE=1"') }
        if ($run.Cartoon) { $modeArgs+=@('-generic_top','"CARTOON_MODE=1"') }
        if ($run.Morph) { $modeArgs+=@('-generic_top','"MORPH_MODE=1"') }
        if ($run.ScharrInverse) { $modeArgs+=@('-generic_top','"SCHARR_INV_MODE=1"') }
        if ($run.Binary) { $modeArgs+=@('-generic_top','"MASK_MODE=9"') }
        if ($run.Erosion) { $modeArgs+=@('-generic_top','"MASK_MODE=10"') }
        if ($run.Dilation) { $modeArgs+=@('-generic_top','"MASK_MODE=11"') }
        if ($run.CloseMask) { $modeArgs+=@('-generic_top','"MASK_MODE=12"') }
        $elaborateLog=$run.Name + '_elaborate_console.log'
        $simulateLog=$run.Name + '_simulate_console.log'
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            @modeArgs work.tb_isp_lighting_integration -s $run.Name `
            -log ($run.Name + '_xelab.log') *> $elaborateLog
        if ($LASTEXITCODE -ne 0) { throw "ISP integration elaboration failed; see $elaborateLog" }
        & (Join-Path $SimBin 'xsim.bat') $run.Name -runall `
            -log ($run.Name + '_xsim.log') *> $simulateLog
        if ($LASTEXITCODE -ne 0) { throw "ISP integration simulation failed; see $simulateLog" }
        $console=[IO.File]::ReadAllText((Join-Path $simulationDir $simulateLog))
        if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b') {
            throw "ISP integration reported an error; see $simulateLog"
        }
        $requiredPasses=@($(if ($run.Motion) { 'ISP_MOTION_INTEGRATION_PASS' } else { 'ISP_LIGHTING_INTEGRATION_PASS' }))
        if ($run.Emboss) { $requiredPasses+='ISP_EMBOSS_INTEGRATION_PASS' }
        if ($run.Cartoon) { $requiredPasses+='ISP_CARTOON_INTEGRATION_PASS' }
        if ($run.Morph) { $requiredPasses+='ISP_MORPH_INTEGRATION_PASS' }
        if ($run.ScharrInverse) { $requiredPasses+='ISP_SCHARR_INVERSE_INTEGRATION_PASS' }
        if ($run.Binary -or $run.Erosion -or $run.Dilation -or $run.CloseMask) { $requiredPasses+='ISP_COLOR_MASK_INTEGRATION_PASS' }
        foreach ($marker in $requiredPasses) {
            $matches=[regex]::Matches($console,"(?m)^$marker\b.*$")
            if ($matches.Count -ne 1) { throw "ISP integration did not pass exactly once: $marker; see $simulateLog" }
            $matches[0].Value.Trim()
        }
    }
} finally {
    Pop-Location
}
