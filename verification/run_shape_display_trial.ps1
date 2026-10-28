param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Shape', 'Display', 'Combined')]
    [string] $Stage,
    [string] $TrialName = '',
    [string] $TdBin = 'D:\TD\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$experimentRoot = Join-Path $projectRoot 'build\shape_display_compression'
$baselineRoot = Join-Path $experimentRoot 'baseline_20261027'
$baselineManifest = Join-Path $baselineRoot 'build\multi_three\reports\source_sha256.csv'
if (-not (Test-Path -LiteralPath $baselineManifest -PathType Leaf)) {
    throw "Frozen baseline manifest is missing: $baselineManifest"
}
if (-not $TrialName) {
    $TrialName = $Stage.ToLowerInvariant() + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
}
if ($TrialName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$') {
    throw 'TrialName must contain only letters, digits, hyphens, and underscores.'
}
$variantRoot = Join-Path $experimentRoot ('variants\' + $TrialName)
$reportRoot = Join-Path $experimentRoot ('reports\' + $TrialName)
if ((Test-Path -LiteralPath $variantRoot) -or (Test-Path -LiteralPath $reportRoot)) {
    throw "Trial already exists: $TrialName"
}
$shapePath = 'user_source/hdl_source/isp/red_target_detect_96.v'
$displayPath = 'user_source/hdl_source/hdmi_mixer.v'
$selectedPaths = @()
if ($Stage -in @('Shape', 'Combined')) { $selectedPaths += $shapePath }
if ($Stage -in @('Display', 'Combined')) { $selectedPaths += $displayPath }

# Every other synthesis input must still match the pre-experiment snapshot.
# This prevents unrelated concurrent edits from becoming part of a comparison.
$baselineRows = @(Import-Csv -LiteralPath $baselineManifest)
foreach ($row in $baselineRows) {
    if ($row.Path -in @($shapePath, $displayPath)) { continue }
    $livePath = Join-Path $projectRoot $row.Path
    if (-not (Test-Path -LiteralPath $livePath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash -ne $row.Hash) {
        throw "Unrelated synthesis input differs from frozen baseline: $($row.Path)"
    }
}
foreach ($relative in @($shapePath, $displayPath)) {
    $expected = @($baselineRows | Where-Object { $_.Path -eq $relative })
    if ($expected.Count -ne 1 -or
        (Get-FileHash -LiteralPath (Join-Path $baselineRoot $relative) -Algorithm SHA256).Hash -ne
        $expected[0].Hash) {
        throw "Frozen RTL does not match baseline manifest: $relative"
    }
}

New-Item -ItemType Directory -Path $variantRoot -Force | Out-Null
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'user_source') -Destination $variantRoot -Recurse
foreach ($relative in @($shapePath, $displayPath)) {
    if ($relative -notin $selectedPaths) {
        Copy-Item -LiteralPath (Join-Path $baselineRoot $relative) `
            -Destination (Join-Path $variantRoot $relative) -Force
    }
}
foreach ($folder in @('td_project', 'verification')) {
    New-Item -ItemType Directory -Path (Join-Path $variantRoot $folder) | Out-Null
}
foreach ($relative in @(
    'td_project/anlogic_edge_osd.al',
    'td_project/anlogic_edge_osd.sdc',
    'verification/run_image_quality_build.ps1'
)) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) `
        -Destination (Join-Path $variantRoot $relative)
}

$variantRows = @(
    foreach ($row in $baselineRows) {
        $snapshotPath = Join-Path $variantRoot $row.Path
        if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
            throw "Snapshot input is missing: $($row.Path)"
        }
        $hash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
        if ($row.Path -notin $selectedPaths -and $hash -ne $row.Hash) {
            throw "Snapshot input changed during capture: $($row.Path)"
        }
        [pscustomobject]@{
            Path = $row.Path
            Hash = $hash
            BaselineHash = $row.Hash
            Changed = ($hash -ne $row.Hash)
        }
    }
)
$variantRows | Export-Csv -LiteralPath (Join-Path $reportRoot 'variant_sources.csv') `
    -Encoding UTF8 -NoTypeInformation
Write-Output "Trial: $TrialName ($Stage)"
Write-Output "Frozen variant: $variantRoot"
$driverOutput = @()
try {
    & (Join-Path $variantRoot 'verification\run_image_quality_build.ps1') `
        -TdBin $TdBin -SkipRoute |
        Tee-Object -Variable driverOutput |
        Tee-Object -FilePath (Join-Path $reportRoot 'driver_output.log')
} finally {
    $workLine = @($driverOutput | Where-Object { $_ -match '^Build output: ' })
    if ($workLine.Count -eq 1) {
        $workRoot = ([string] $workLine[0]).Substring('Build output: '.Length)
        foreach ($name in @(
            'system_rtl.area', 'system_gate.area', 'system_gate.timing',
            'source_sha256.csv', 'console.log', 'build.tcl', 'build_driver.ps1'
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
$toolManifest = @(Import-Csv -LiteralPath (Join-Path $reportRoot 'source_sha256.csv'))
if ($toolManifest.Count -ne $variantRows.Count) {
    throw 'The TD synthesis manifest has a different number of inputs than the frozen variant.'
}
foreach ($row in $variantRows) {
    $toolRow = @($toolManifest | Where-Object { $_.Path -eq $row.Path })
    if ($toolRow.Count -ne 1 -or $toolRow[0].Hash -ne $row.Hash) {
        throw "TD synthesis input does not match frozen variant: $($row.Path)"
    }
}
$areaText = Get-Content -LiteralPath $gateReport -Raw
$totals = [ordered]@{ Stage = $Stage; Trial = $TrialName }
foreach ($entry in @(
    @('LUT', '(?m)^#lut\s+(\d+)'),
    @('Registers', '(?m)^#reg\s+(\d+)'),
    @('GateSliceEstimate', '(?m)^#slice\*\s+(\d+)'),
    @('ERAM', '(?m)^#eram\s+(\d+)'),
    @('DSP', '(?m)^#dsp\s+(\d+)')
)) {
    $match = [regex]::Match($areaText, $entry[1])
    if (-not $match.Success) { throw "Missing resource in gate report: $($entry[0])" }
    $totals[$entry[0]] = [int] $match.Groups[1].Value
}
[pscustomobject] $totals |
    Export-Csv -LiteralPath (Join-Path $reportRoot 'resource_totals.csv') `
        -NoTypeInformation -Encoding UTF8
Write-Output "TRIAL_SYNTHESIS_PASS reports=$reportRoot"
[pscustomobject] $totals | Format-List
