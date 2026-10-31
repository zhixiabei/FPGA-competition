param(
    [string] $ReferenceRtl = '',
    [int] $TimeoutSeconds = 300,
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [ValidateSet('Portable','Vendor')]
    [string] $MemoryModel = 'Portable',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ReferenceRtl) {
    # The resource-optimization baseline is a pre-edit workspace snapshot.
    $ReferenceRtl = Join-Path $projectRoot 'build\resource_optimization\baseline\scharr_edge_detect_96.v'
}
$ReferenceRtl = (Resolve-Path -LiteralPath $ReferenceRtl).Path
if ($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_scharr_morphology_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    (Join-Path $projectRoot 'user_source\hdl_source\isp\scharr_edge_detect_96.v'),
    (Join-Path $projectRoot 'user_source\hdl_source\isp\rgb_edge_switch_96.v'),
    (Join-Path $PSScriptRoot 'tb_scharr_edge_detect_96.sv'),
    (Join-Path $PSScriptRoot 'tb_scharr_morphology_equivalence.sv')
)
if($MemoryModel -eq 'Vendor') {
    foreach($name in @('ph1p_logic_eram.v','ph1p_logic_dram.v','ph1p_logic_dram64x8.v',
                       'ph1p_phy_mslice.v','ph1p_phy_dramhardcon.v','ph1p_phy_gsr.v')) {
        $sources += Join-Path $TdSimLib $name
    }
}
$compiledSources = @()
$hashes = foreach ($source in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $destination
    $compiledSources += $destination
    [pscustomobject]@{
        File = Split-Path -Leaf $source
        Source = $source
        SHA256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    }
}
$referenceCopy = Join-Path $simulationDir 'scharr_edge_detect_96_reference.v'
$referenceText = [IO.File]::ReadAllText($ReferenceRtl)
$referenceText = [regex]::Replace($referenceText,
    '\bscharr_edge_detect_96\b', 'scharr_edge_detect_96_reference')
$referenceText = [regex]::Replace($referenceText,
    '\bscharr_window_4\b', 'scharr_window_4_reference')
[IO.File]::WriteAllText($referenceCopy, $referenceText, [Text.UTF8Encoding]::new($false))
$compiledSources += $referenceCopy
$referenceHash = (Get-FileHash -LiteralPath $ReferenceRtl -Algorithm SHA256).Hash
$hashes += [pscustomobject]@{
    File = Split-Path -Leaf $referenceCopy
    Source = $ReferenceRtl
    SHA256 = $referenceHash
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$tclSources = ($compiledSources | ForEach-Object { '{' + $_.Replace('\', '/') + '}' }) -join ' '
$ramDefine=if($MemoryModel -eq 'Portable') {'+define+SCHARR_PORTABLE_RAM'} else {''}
$gsrTop=if($MemoryModel -eq 'Vendor') {' work.PH1P_PHY_GSR'} else {''}
$simulations = @(
    [pscustomobject]@{
        Name = 'equivalence'
        Setup = "vlib work`nvlog -sv $ramDefine $tclSources"
        Top = 'work.tb_scharr_morphology_equivalence'+$gsrTop
        Pass = '(?m)^\s*(?:#\s*)?SCHARR_MORPHOLOGY_EQUIVALENCE_PASS\b'
    },
    [pscustomobject]@{
        Name = 'image_gaussian_on'
        Setup = ''
        Top = 'work.tb_scharr_edge_detect_96'+$gsrTop
        Pass = '(?m)^\s*(?:#\s*)?SCHARR_EDGE_TEST_PASS size=64x48 gaussian=1\b'
    }
)
# The image oracle includes a fixed-Gaussian selector; Gaussian-off behavior
# is checked by the baseline differential cases above.
Write-Output "Simulation output: $simulationDir"
Write-Output "Reference snapshot: $ReferenceRtl"
Write-Output "Reference snapshot SHA256 (before module renaming): $referenceHash"
foreach ($simulation in $simulations) {
    # A separate process per top supports ModelSim versions that exit at $finish.
    $runScript = @"
onerror {quit -code 1 -force}
onbreak {resume}
$($simulation.Setup)
vsim -onfinish stop -t ps $($simulation.Top)
run -all
quit -code 0 -force
"@
    $scriptName = $simulation.Name + '.do'
    [IO.File]::WriteAllText((Join-Path $simulationDir $scriptName),
        $runScript, [Text.UTF8Encoding]::new($false))
    $consolePath = Join-Path $simulationDir ($simulation.Name + '.console.log')
    $errorPath = Join-Path $simulationDir ($simulation.Name + '.stderr.log')
    $process = Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
        -ArgumentList @('-c', '-do', $scriptName, '-l', ($simulation.Name + '.transcript.log')) `
        -WorkingDirectory $simulationDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $consolePath -RedirectStandardError $errorPath
    $processHandle=$process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force
        throw "Scharr morphology simulation timed out: $consolePath"
    }
    $process.WaitForExit()
    $process.Refresh()
    $console = [IO.File]::ReadAllText($consolePath)
    if ($process.ExitCode -ne 0 -or
        $console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
        $console -notmatch $simulation.Pass) {
        throw "Scharr morphology simulation failed: $consolePath"
    }
    [regex]::Matches($console,
        '(?m)^\s*(?:#\s*)?(?:SCHARR_MORPHOLOGY_(?:CASE|EQUIVALENCE)_PASS|SCHARR_EDGE_TEST_PASS|MORPHOLOGY_TEST_PASS)\b.*$') |
        ForEach-Object { $_.Value.Trim() -replace '^#\s*', '' }
}
