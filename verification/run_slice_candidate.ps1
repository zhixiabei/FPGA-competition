param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9_-]*$')]
    [string] $Name,
    [Parameter(Mandatory = $true)]
    [string] $CandidateRoot,
    [switch] $SkipRoute
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$baseline = Join-Path $projectRoot 'build\slice_compression\baseline_project'
$experiment = Join-Path $projectRoot ('build\slice_compression\experiments\' + $Name)
$candidate = (Resolve-Path -LiteralPath $CandidateRoot).Path
if (Test-Path -LiteralPath $experiment) {
    throw "Experiment already exists; use a new name: $experiment"
}
$manifest = Import-Csv -LiteralPath (Join-Path $baseline 'build\release\source_sha256.csv')
$allowed = @{}
foreach ($entry in $manifest) { $allowed[$entry.Path.Replace('\', '/')] = $true }
$overrides = @(Get-ChildItem -LiteralPath $candidate -File -Recurse)
if (-not $overrides.Count) { throw "Candidate has no files: $candidate" }
foreach ($file in $overrides) {
    $relative = $file.FullName.Substring($candidate.Length + 1).Replace('\', '/')
    if (-not $allowed.ContainsKey($relative)) {
        throw "Candidate override is not a production input: $relative"
    }
}
New-Item -ItemType Directory -Path $experiment | Out-Null
foreach ($entry in $manifest) {
    $source = Join-Path $baseline $entry.Path
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.Hash) {
        throw "Frozen baseline has changed: $source"
    }
    $destination = Join-Path $experiment $entry.Path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
}
foreach ($file in $overrides) {
    $relative = $file.FullName.Substring($candidate.Length + 1)
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $experiment $relative)
}
New-Item -ItemType Directory -Path (Join-Path $experiment 'verification') | Out-Null
Copy-Item -LiteralPath (Join-Path $baseline 'verification\run_image_quality_build.ps1') `
    -Destination (Join-Path $experiment 'verification')
$driver = Join-Path $experiment 'verification\run_image_quality_build.ps1'
$runLog = Join-Path $experiment 'run.log'
Write-Output "Independent candidate project: $experiment"
# No GenerateBit: experiments must not publish over the production release.
& $driver -SkipRoute:$SkipRoute *>&1 | Tee-Object -FilePath $runLog
if (-not $?) { throw "Candidate failed; see $runLog" }
