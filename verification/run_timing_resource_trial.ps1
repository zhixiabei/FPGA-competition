param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Baseline', 'Mask', 'Display', 'Cnn', 'Motion', 'Combined')]
    [string] $Stage,
    [string] $TrialName = '',
    [string] $TdBin = 'D:\TD\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$experimentRoot = Join-Path $projectRoot 'build\timing_resource_repair_20261027'
$baselineRoot = Join-Path $experimentRoot 'baseline'
$baselineManifest = Join-Path $baselineRoot 'source_sha256.csv'
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
$pathsByStage = @{
    Mask = @('user_source/hdl_source/isp/red_target_detect_96.v')
    Display = @(
        'user_source/hdl_source/hdmi_mixer.v',
        'user_source/hdl_source/osd_char_lib.v'
    )
    Cnn = @('user_source/hdl_source/fruit_merged/fruitcnn128_core.v')
    Motion = @('user_source/hdl_source/isp/target_detect_switch_96.v')
}
$selectedPaths = if ($Stage -eq 'Baseline') {
    @()
} elseif ($Stage -eq 'Combined') {
    @($pathsByStage.Keys | ForEach-Object { $pathsByStage[$_] })
} else {
    @($pathsByStage[$Stage])
}
$baselineRows = @(Import-Csv -LiteralPath $baselineManifest)
$captureHashes = @{}
foreach ($relative in $selectedPaths) {
    $captureHashes[$relative] =
        (Get-FileHash -LiteralPath (Join-Path $projectRoot $relative) -Algorithm SHA256).Hash
}
New-Item -ItemType Directory -Path $variantRoot | Out-Null
New-Item -ItemType Directory -Path $reportRoot | Out-Null

# Copy each declared baseline input, substituting only this trial's modules.
# Other agents may edit separate live modules without contaminating the trial.
$variantRows = @(
    foreach ($row in $baselineRows) {
        $frozenPath = Join-Path $baselineRoot $row.Path
        if ((Get-FileHash -LiteralPath $frozenPath -Algorithm SHA256).Hash -ne $row.Hash) {
            throw "Frozen baseline input changed: $($row.Path)"
        }
        $snapshotPath = Join-Path $variantRoot $row.Path
        New-Item -ItemType Directory -Path (Split-Path -Parent $snapshotPath) -Force | Out-Null
        $sourcePath = if ($row.Path -in $selectedPaths) {
            Join-Path $projectRoot $row.Path
        } else {
            $frozenPath
        }
        Copy-Item -LiteralPath $sourcePath -Destination $snapshotPath
        $hash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
        $expectedHash = if ($row.Path -in $selectedPaths) {
            $captureHashes[$row.Path]
        } else {
            $row.Hash
        }
        if ($hash -ne $expectedHash) {
            throw "Input changed while creating snapshot: $($row.Path)"
        }
        [pscustomobject]@{
            Path = $row.Path
            Hash = $hash
            BaselineHash = $row.Hash
            Changed = ($hash -ne $row.Hash)
        }
    }
)
foreach ($relative in $selectedPaths) {
    if ((Get-FileHash -LiteralPath (Join-Path $projectRoot $relative) -Algorithm SHA256).Hash -ne
        $captureHashes[$relative]) {
        throw "Selected input changed during capture: $relative"
    }
}
New-Item -ItemType Directory -Path (Join-Path $variantRoot 'verification') | Out-Null
Copy-Item -LiteralPath (Join-Path $baselineRoot 'verification\run_image_quality_build.ps1') `
    -Destination (Join-Path $variantRoot 'verification\run_image_quality_build.ps1')
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
            'system_gate.v', 'system_gate.db',
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
    throw 'TD input count differs from the frozen snapshot.'
}
foreach ($row in $variantRows) {
    $toolRow = @($toolManifest | Where-Object { $_.Path -eq $row.Path })
    if ($toolRow.Count -ne 1 -or $toolRow[0].Hash -ne $row.Hash) {
        throw "TD input differs from the captured snapshot: $($row.Path)"
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
$timingText = Get-Content -LiteralPath (Join-Path $reportRoot 'system_gate.timing') -Raw
$clockNames = @{}
foreach ($clock in [regex]::Matches($timingText,
    '(?m)^\s+(clk\d+):\s+[\d.]+\s+\d+\s+(\S+)\s*$')) {
    $clockNames[$clock.Groups[1].Value] = $clock.Groups[2].Value
}
$clockRows = @(
    foreach ($clock in [regex]::Matches($timingText,
        '(?m)^\s+(clk\d+)\s+local\s+(?:-?[\d.]+\s+){6}(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+')) {
        [pscustomobject]@{
            Clock = $clockNames[$clock.Groups[1].Value]
            SetupWnsNs = $clock.Groups[2].Value
            SetupTnsNs = $clock.Groups[3].Value
            HoldWnsNs = $clock.Groups[4].Value
            HoldTnsNs = $clock.Groups[5].Value
        }
    }
)
if ($clockRows.Count -ne $clockNames.Count) {
    throw 'Could not parse every clock from the synthesized timing summary.'
}
$clockRows | Export-Csv -LiteralPath (Join-Path $reportRoot 'clock_slacks.csv') `
    -NoTypeInformation -Encoding UTF8
Write-Output "TIMING_RESOURCE_TRIAL_PASS reports=$reportRoot"
[pscustomobject] $totals | Format-List
