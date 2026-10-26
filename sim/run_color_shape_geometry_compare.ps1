param(
    [string] $BaselineRef = '13bcf60',
    [int] $TimeoutSeconds = 180,
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$comparisonDir = Join-Path $env:TEMP ('anlogic_shape_geometry_compare_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $comparisonDir | Out-Null
$baselineZip = Join-Path $comparisonDir 'baseline.zip'
$baselineDir = Join-Path $comparisonDir 'baseline'
$rtlRelative = 'user_source/hdl_source/isp/red_target_detect_96.v'
& git -C $projectRoot archive --format=zip "--output=$baselineZip" $BaselineRef $rtlRelative
if ($LASTEXITCODE -ne 0) { throw "Cannot archive baseline RTL: $BaselineRef" }
Expand-Archive -LiteralPath $baselineZip -DestinationPath $baselineDir

# Snapshot the final production file exactly. Generate only the deliberately
# relaxed span experiment; the final column never uses a rewritten RTL copy.
$finalPath = Join-Path $comparisonDir 'final.v'
Copy-Item -LiteralPath (Join-Path $projectRoot $rtlRelative) -Destination $finalPath
$relaxedText = [IO.File]::ReadAllText($finalPath)
$edits = @(
    # Keep the original wires for the independent pixel-tolerance branch.
    # Halving their exact 8*span values changes only this experiment's ratio.
    @('isotropic<=w8 <= h8+height && h8 <= w8+width &&',
      'isotropic<=(w8>>1) <= (h8>>1)+height && (h8>>1) <= (w8>>1)+width &&'),
    @('u8 <= v8+v_span && v8 <= u8+u_span;',
      '(u8>>1) <= (v8>>1)+v_span && (v8>>1) <= (u8>>1)+u_span;')
)
foreach ($edit in $edits) {
    if ([regex]::Matches($relaxedText,[regex]::Escape($edit[0])).Count -ne 1) {
        throw "Final production span guard no longer matches this experiment: $($edit[0])"
    }
    $relaxedText = $relaxedText.Replace($edit[0],$edit[1])
}
$relaxedPath = Join-Path $comparisonDir 'relaxed_span_experiment.v'
[IO.File]::WriteAllText($relaxedPath,$relaxedText,[Text.UTF8Encoding]::new($false))
$variants = @(
    [pscustomobject]@{
        Name='baseline_span9of8_center1of32'
        Path=(Join-Path $baselineDir $rtlRelative)
        Expected=@{34=0;35=0;36=0;37=0;38=0;39=0}
    },
    [pscustomobject]@{
        Name='experiment_span5of4_center1of16'
        Path=$relaxedPath
        Expected=@{34=1;35=3;36=1;37=1;38=1;39=1}
    },
    [pscustomobject]@{
        Name='final_span9of8_pixel2_center1of16'
        Path=$finalPath
        Expected=@{34=0;35=0;36=1;37=0;38=0;39=1}
    }
)
$scenarios = @{
    34='rectangle 65 columns by 55 rows'
    35='ellipse with semiaxes 35 and 30'
    36='off-center trapezoid top 53 bottom 65 height 65'
    37='square missing 17 by 24 corner'
    38='radius 32 circle with rightmost 9-column cap removed'
    39='centered trapezoid top 35 bottom 65 height 65'
}
$records = @()
Write-Output "Comparison output: $comparisonDir"
foreach ($variant in $variants) {
    $output = @(& (Join-Path $PSScriptRoot 'run_color_shape_target.ps1') `
        -Mode Portable -GeometryProbeOnly -RtlSource $variant.Path `
        -TimeoutSeconds $TimeoutSeconds -ModelSimBin $ModelSimBin)
    $output | ForEach-Object { Write-Output "$($variant.Name): $_" }
    [IO.File]::WriteAllLines((Join-Path $comparisonDir ($variant.Name + '_runner.log')),
        [string[]]$output,[Text.UTF8Encoding]::new($false))
    $directoryLines = @($output | Where-Object { $_ -match '^Simulation output: ' })
    if ($directoryLines.Count -ne 1) { throw 'Expected exactly one simulation output directory.' }
    $innerDir = $directoryLines[0] -replace '^Simulation output: ',''
    Copy-Item -LiteralPath (Join-Path $innerDir 'portable_console.log') `
        -Destination (Join-Path $comparisonDir ($variant.Name + '_console.log'))
    Copy-Item -LiteralPath (Join-Path $innerDir 'source_sha256.csv') `
        -Destination (Join-Path $comparisonDir ($variant.Name + '_source_sha256.csv'))
    $observed = @{}
    foreach ($line in $output) {
        if ($line -match '^COLOR_SHAPE_GEOMETRY_PROBE pattern=(\d+) shape=(\d+) box=(.*)$') {
            $pattern = [int]$Matches[1]
            $shape = [int]$Matches[2]
            $box = $Matches[3]
            if ($observed.ContainsKey($pattern) -or
                -not $variant.Expected.ContainsKey($pattern) -or
                $shape -ne $variant.Expected[$pattern]) {
                throw "Unexpected geometry result variant=$($variant.Name) pattern=$pattern shape=$shape"
            }
            $observed[$pattern]=$shape
            $records += [pscustomobject]@{
                Variant=$variant.Name
                Pattern=$pattern
                Scenario=$scenarios[$pattern]
                Shape=$shape
                Expected=$variant.Expected[$pattern]
                Box=$box
                RtlSHA256=(Get-FileHash -LiteralPath $variant.Path -Algorithm SHA256).Hash
                SimulationDirectory=$innerDir
            }
        }
    }
    if ($observed.Count -ne 6) { throw "Missing geometry probes for $($variant.Name)" }
}
$records | Export-Csv -LiteralPath (Join-Path $comparisonDir 'comparison.csv') -NoTypeInformation
Write-Output "COLOR_SHAPE_GEOMETRY_COMPARE_PASS variants=$($variants.Count) probes=$($records.Count) baseline=$BaselineRef"
