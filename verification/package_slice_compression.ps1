param([string] $OutputPath = 'build/verification/slice_compression_regression.zip')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$output = [IO.Path]::GetFullPath((Join-Path $root $OutputPath))
if (-not $output.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The evidence archive must stay inside the project workspace'
}
if (Test-Path -LiteralPath $output) {
    throw "Archive already exists; choose another OutputPath: $output"
}

$release = Get-Content -LiteralPath (Join-Path $root 'build/release/release_manifest.json') -Raw |
    ConvertFrom-Json
$baseline = Get-Content -LiteralPath (Join-Path $root 'build/slice_compression/baseline_release/release/release_manifest.json') -Raw |
    ConvertFrom-Json
$sources = @(Import-Csv -LiteralPath (Join-Path $root 'build/release/source_sha256.csv'))
function Get-SourceFingerprint([object[]] $Entries) {
    $text = ($Entries | Sort-Object Path | ForEach-Object { $_.Hash + '  ' + $_.Path }) -join "`n"
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '')
    } finally {
        $hasher.Dispose()
    }
}
if ((Get-SourceFingerprint $sources) -ne $release.source_fingerprint_sha256) {
    throw 'The production source manifest differs from the release fingerprint'
}
foreach ($source in $sources) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $source.Path) -Algorithm SHA256).Hash -ne $source.Hash) {
        throw "Source differs from the released build: $($source.Path)"
    }
}
$baselineRoot = Join-Path $root 'build/slice_compression/baseline_project'
$baselineSources = @(Import-Csv -LiteralPath (Join-Path $baselineRoot 'build/release/source_sha256.csv'))
if ((Get-SourceFingerprint $baselineSources) -ne $baseline.source_fingerprint_sha256) {
    throw 'The frozen baseline manifest differs from its release fingerprint'
}
foreach ($source in $baselineSources) {
    if ((Get-FileHash -LiteralPath (Join-Path $baselineRoot $source.Path) -Algorithm SHA256).Hash -ne $source.Hash) {
        throw "Frozen baseline input has changed: $($source.Path)"
    }
}
if ((Get-FileHash -LiteralPath (Join-Path $root 'build/slice_compression/baseline_release/best_result/anlogic_edge_osd.bit') -Algorithm SHA256).Hash -ne
    $baseline.bitstream.sha256) {
    throw 'The frozen baseline bitstream differs from its release manifest'
}
if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'run_image_quality_build.ps1') -Algorithm SHA256).Hash -ne
    $release.toolchain_fingerprint_sha256) {
    throw 'The build driver differs from the release manifest'
}
if ((Get-FileHash -LiteralPath (Join-Path $root $release.bitstream.path) -Algorithm SHA256).Hash -ne
    $release.bitstream.sha256) {
    throw 'The published bitstream differs from the release manifest'
}
if ($release.timing.status -ne 'passed' -or $release.timing.mode -ne 'final_routed' -or
    $release.timing.setup_slack_ns -lt 0 -or $release.timing.hold_slack_ns -lt 0 -or
    $release.resource_budget.status -ne 'passed') {
    throw 'Final routed timing and resource checks are required before packaging'
}
$baselineArea = [IO.File]::ReadAllText((Join-Path $root 'build/slice_compression/baseline_release/release/system_phy.area'))
$finalArea = [IO.File]::ReadAllText((Join-Path $root 'build/release/system_phy.area'))
foreach ($resource in @('slice', 'lut6', 'reg', 'eram', 'dsp')) {
    $pattern = '(?m)^#' + $resource + '[ \t]+(\d+)'
    $before = [regex]::Match($baselineArea, $pattern)
    $after = [regex]::Match($finalArea, $pattern)
    if (-not $before.Success -or -not $after.Success -or
        [int]$after.Groups[1].Value -gt [int]$before.Groups[1].Value -or
        ($resource -eq 'slice' -and [int]$after.Groups[1].Value -ge [int]$before.Groups[1].Value)) {
        throw "Resource acceptance failed: $resource"
    }
}

# Entries retain workspace-relative paths so the frozen baseline and runners
# resolve the same inputs when the archive is extracted into a fresh directory.
$files = @{}
function Add-PackageFile([string] $Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    if (-not $absolute.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package input is outside the workspace: $absolute"
    }
    $relative = $absolute.Substring($root.Length + 1).Replace('\', '/')
    $files[$relative] = $absolute
}
foreach ($source in $sources) {
    Add-PackageFile (Join-Path $root $source.Path)
}
foreach ($folder in @(
    'build/slice_compression/baseline_project',
    'build/slice_compression/baseline_release',
    'build/slice_compression/candidates',
    'build/slice_compression/implementation',
    'build/slice_compression/verification',
    'build/release',
    'td_project/anlogic_edge_osd_Runs/best_result'
)) {
    Get-ChildItem -LiteralPath (Join-Path $root $folder) -File -Recurse |
        ForEach-Object { Add-PackageFile $_.FullName }
}
foreach ($folder in @('sim', 'verification', 'docs')) {
    Get-ChildItem -LiteralPath (Join-Path $root $folder) -File |
        Where-Object { $_.Extension -in @('.ps1', '.sv', '.v', '.vh', '.tcl', '.cmd', '.bat', '.do', '.md') } |
        ForEach-Object { Add-PackageFile $_.FullName }
}
Add-PackageFile (Join-Path $root 'README.md')
Add-PackageFile (Join-Path $root '.gitignore')
$earlierBaseline = Join-Path $root 'build/resource_optimization/baseline'
if (Test-Path -LiteralPath $earlierBaseline -PathType Container) {
    Get-ChildItem -LiteralPath $earlierBaseline -File -Recurse |
        ForEach-Object { Add-PackageFile $_.FullName }
}
$hashManifest = Join-Path $root 'build/slice_compression/package_sha256.csv'
$entries = @($files.Keys | Sort-Object | ForEach-Object {
    [pscustomobject]@{
        Path = $_
        Hash = (Get-FileHash -LiteralPath $files[$_] -Algorithm SHA256).Hash
    }
})
$entries | Export-Csv -LiteralPath $hashManifest -NoTypeInformation -Encoding UTF8
Add-PackageFile $hashManifest

New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
$staged = $output + '.partial.' + [guid]::NewGuid().ToString('N')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($staged, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in ($files.Keys | Sort-Object)) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $files[$relative],
            $relative, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $archive.Dispose()
}
$archive = [IO.Compression.ZipFile]::OpenRead($staged)
try {
    if ($archive.Entries.Count -ne $files.Count) { throw 'Evidence archive entry count mismatch' }
    foreach ($entry in $entries) {
        $stream = $archive.GetEntry($entry.Path).Open()
        $hasher = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '')
            if ($hash -ne $entry.Hash) { throw "Archive checksum mismatch: $($entry.Path)" }
        } finally {
            $hasher.Dispose()
            $stream.Dispose()
        }
    }
} finally {
    $archive.Dispose()
}
[IO.File]::Move($staged, $output)
Write-Output "SLICE_COMPRESSION_PACKAGE_PASS baseline=$($baseline.version) final=$($release.version) inputs=$($sources.Count) entries=$($files.Count)"
Write-Output "Evidence archive: $output"
Write-Output "Evidence SHA256: $((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash)"
