param(
    [ValidateSet('Baseline','Single')]
    [string] $Stage = 'Single',
    [string] $TrialName = '',
    [string] $DetectorSource = '',
    [switch] $CurrentProject,
    [string] $TdBin = 'D:\TD\bin'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$experimentRoot = Join-Path $projectRoot 'build\single_target_20261028'
$baselineRoot = Join-Path $experimentRoot 'baseline'
$baselineManifest = Join-Path $baselineRoot 'source_sha256.csv'
if (-not (Test-Path -LiteralPath $baselineManifest -PathType Leaf)) {
    throw "Frozen baseline manifest is missing: $baselineManifest"
}
if (-not $TrialName) {
    $TrialName = $Stage.ToLowerInvariant()+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss')
}
if ($TrialName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$') {
    throw 'TrialName must contain only letters, digits, hyphens and underscores.'
}
$variantRoot = Join-Path $experimentRoot ('variants\'+$TrialName)
$reportRoot = Join-Path $experimentRoot ('reports\'+$TrialName)
if ((Test-Path -LiteralPath $variantRoot) -or (Test-Path -LiteralPath $reportRoot)) {
    throw "Trial already exists: $TrialName"
}
$selectedPaths = if ($Stage -eq 'Single') {
    @(
        'user_source/hdl_source/design_top_wrapper.v',
        'user_source/hdl_source/isp/isp_top.v',
        'user_source/hdl_source/isp/red_target_detect_96.v',
        'user_source/hdl_source/isp/target_detect_switch_96.v',
        'user_source/hdl_source/target_frame_bridge.v',
        'user_source/hdl_source/hdmi_mixer.v'
    )
} else { @() }
if ($CurrentProject) {
    if ($Stage -ne 'Single') { throw 'CurrentProject requires Stage Single.' }
    $selectedPaths += 'td_project/anlogic_edge_osd.al'
}
$sourceOverrides = @{}
if ($DetectorSource) {
    if ($Stage -ne 'Single') { throw 'DetectorSource requires Stage Single.' }
    $sourceOverrides['user_source/hdl_source/isp/red_target_detect_96.v'] =
        (Resolve-Path -LiteralPath $DetectorSource -ErrorAction Stop).Path
}
function Get-SelectedSource([string] $RelativePath) {
    if ($sourceOverrides.ContainsKey($RelativePath)) {
        return $sourceOverrides[$RelativePath]
    }
    return Join-Path $projectRoot $RelativePath
}
$baselineRows = @(Import-Csv -LiteralPath $baselineManifest)
$captureHashes = @{}
foreach ($relative in $selectedPaths) {
    $captureHashes[$relative] =
        (Get-FileHash -LiteralPath (Get-SelectedSource $relative) -Algorithm SHA256).Hash
}
New-Item -ItemType Directory -Path $variantRoot | Out-Null
New-Item -ItemType Directory -Path $reportRoot | Out-Null
$variantRows = @(
    foreach ($row in $baselineRows) {
        $frozenPath = Join-Path $baselineRoot $row.Path
        if ((Get-FileHash -LiteralPath $frozenPath -Algorithm SHA256).Hash -ne $row.Hash) {
            throw "Frozen baseline changed: $($row.Path)"
        }
        $sourcePath = if ($row.Path -in $selectedPaths) {
            Get-SelectedSource $row.Path
        } else { $frozenPath }
        $snapshotPath = Join-Path $variantRoot $row.Path
        New-Item -ItemType Directory -Path (Split-Path -Parent $snapshotPath) -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $snapshotPath
        $hash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
        $expected = if ($row.Path -in $selectedPaths) {
            $captureHashes[$row.Path]
        } else { $row.Hash }
        if ($hash -ne $expected) { throw "Input changed during capture: $($row.Path)" }
        [pscustomobject]@{
            Path=$row.Path; Hash=$hash; BaselineHash=$row.Hash; Changed=($hash -ne $row.Hash)
        }
    }
)
foreach ($relative in $selectedPaths) {
    if ((Get-FileHash -LiteralPath (Get-SelectedSource $relative) -Algorithm SHA256).Hash -ne
        $captureHashes[$relative]) {
        throw "Selected input changed during capture: $relative"
    }
}
New-Item -ItemType Directory -Path (Join-Path $variantRoot 'verification') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $baselineRoot 'verification\run_image_quality_build.ps1') `
    -Destination (Join-Path $variantRoot 'verification\run_image_quality_build.ps1')
$variantRows | Export-Csv -LiteralPath (Join-Path $reportRoot 'variant_sources.csv') `
    -Encoding UTF8 -NoTypeInformation
Write-Output "Trial: $TrialName ($Stage)"
Write-Output "Frozen variant: $variantRoot"
$driverOutput = @()
try {
    # The driver copies this frozen variant to a fresh TEMP directory.
    # SkipRoute never runs placement, routing, bitgen or release publication.
    & (Join-Path $variantRoot 'verification\run_image_quality_build.ps1') -TdBin $TdBin -SkipRoute |
        Tee-Object -Variable driverOutput |
        Tee-Object -FilePath (Join-Path $reportRoot 'driver_output.log')
} finally {
    $workLine = @($driverOutput | Where-Object { $_ -match '^Build output: ' })
    if ($workLine.Count -eq 1) {
        $workRoot = ([string]$workLine[0]).Substring('Build output: '.Length)
        foreach ($name in @(
            'system_rtl.area','system_gate.area','system_gate.timing',
            'system_gate.v','system_gate.db','source_sha256.csv',
            'console.log','build.tcl','build_driver.ps1'
        )) {
            $sourcePath = Join-Path $workRoot $name
            if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
                Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $reportRoot $name)
            }
        }
    }
}
$gateReport = Join-Path $reportRoot 'system_gate.area'
if (-not (Test-Path -LiteralPath $gateReport -PathType Leaf)) {
    throw "Synthesis report was not produced: $reportRoot"
}
$toolRows = @(Import-Csv -LiteralPath (Join-Path $reportRoot 'source_sha256.csv'))
if ($toolRows.Count -ne $variantRows.Count) {
    throw 'TD input count differs from the frozen variant.'
}
foreach ($row in $variantRows) {
    $toolRow = @($toolRows | Where-Object { $_.Path -eq $row.Path })
    if ($toolRow.Count -ne 1 -or $toolRow[0].Hash -ne $row.Hash) {
        throw "TD input differs from the frozen variant: $($row.Path)"
    }
}
$areaText = Get-Content -LiteralPath $gateReport -Raw
$totals = [ordered]@{Stage=$Stage; Trial=$TrialName}
foreach ($entry in @(
    @('LUT','(?m)^#lut\s+(\d+)'),
    @('Registers','(?m)^#reg\s+(\d+)'),
    @('GateSliceEstimate','(?m)^#slice\*\s+(\d+)'),
    @('ERAM','(?m)^#eram\s+(\d+)'),
    @('DSP','(?m)^#dsp\s+(\d+)')
)) {
    $match = [regex]::Match($areaText,$entry[1])
    if (-not $match.Success) { throw "Resource missing from report: $($entry[0])" }
    $totals[$entry[0]] = [int]$match.Groups[1].Value
}
[pscustomobject]$totals | Export-Csv -LiteralPath (Join-Path $reportRoot 'resource_totals.csv') `
    -NoTypeInformation -Encoding UTF8
Write-Output "SINGLE_TARGET_TRIAL_PASS stage=$Stage reports=$reportRoot"
[pscustomobject]$totals | Format-List
