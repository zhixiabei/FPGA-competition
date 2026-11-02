param(
    [string] $BaselineDirectory='build/ae_awb_fix/baseline',
    [Parameter(Mandatory=$true)][string] $CandidateDirectory,
    [string] $OutputPath='build/ae_awb_fix/physical_comparison.json',
    [hashtable] $ResourceLimits=@{}
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
function Resolve-Input([string] $Path) {
    if([IO.Path]::IsPathRooted($Path)) {return [IO.Path]::GetFullPath($Path)}
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}
function Read-Number([string] $Text,[string] $Pattern) {
    $matches=[regex]::Matches($Text,$Pattern)
    if($matches.Count -ne 1) {throw "Missing or ambiguous metric: $Pattern"}
    return [double]::Parse($matches[0].Groups[1].Value,
        [Globalization.CultureInfo]::InvariantCulture)
}
function Read-Metrics([string] $Directory) {
    $area=[IO.File]::ReadAllText((Join-Path $Directory 'system_phy.area'))
    $route=[IO.File]::ReadAllText((Join-Path $Directory 'route.qor'))
    $place=[IO.File]::ReadAllText((Join-Path $Directory 'place.qor'))
    $timing=[IO.File]::ReadAllText((Join-Path $Directory 'system_pr.timing'))
    if($timing -notmatch '(?m)^Confidence\s*:\s*Routed\s*$' -or
       $timing -notmatch '(?m)^Check Corner\s*:\s*Both \(Slow and Fast\)\s*$') {
        throw 'Comparison requires final routed timing at both corners'
    }
    $metrics=[ordered]@{}
    foreach($name in 'slice','lut6','reg','eram','dsp') {
        $metrics[$name]=Read-Number $area ('(?m)^#'+$name+'\s+(\d+)\b')
    }
    foreach($item in @(
        @{Name='wire_length';Label='Wire length'},
        @{Name='setup_violations';Label='Num of violated S-EP'},
        @{Name='hold_violations';Label='Num of violated H-EP'}
    )) {
        $metrics[$item.Name]=Read-Number $route (
            '(?m)^\|\s*'+[regex]::Escape($item.Label)+'\s*\|\s*(\d+)\s*\|\s*$')
    }
    foreach($item in @(
        @{Name='place_top1_util';Label='Top 1% tile util'},
        @{Name='place_top1_avg_util';Label='Top 1% tile avg util'},
        @{Name='place_over100_tiles';Label='Over 100% util #tile'},
        @{Name='place_max_level';Label='Max level'}
    )) {
        $metrics[$item.Name]=Read-Number $place (
            '(?m)^\|\s*'+[regex]::Escape($item.Label)+'\s*\|\s*([\d.]+)%?\s*\|\s*$')
    }
    foreach($kind in 'SWNS','STNS','HWNS','HTNS') {
        $metrics[$kind]=Read-Number $timing ([regex]::Escape($kind)+':\s*(-?[\d.]+)ns')
    }
    return $metrics
}
$baselineRoot=Resolve-Input $BaselineDirectory
$candidateRoot=Resolve-Input $CandidateDirectory
$baseline=Read-Metrics $baselineRoot
$candidate=Read-Metrics $candidateRoot
# Explicit ceilings implement the later, modest-growth acceptance policy.
# Without them, preserve the archived experiment's no-increase comparison.
if($ResourceLimits.Count) {
    $capacities=@{slice=21216;lut6=21216;reg=42432;eram=108;dsp=40}
    if($ResourceLimits.Count -ne $capacities.Count) {
        throw 'Specify all five resource limits for the modest-growth policy'
    }
    foreach($name in $capacities.Keys) {
        $value=0
        if(-not $ResourceLimits.ContainsKey($name) -or
           -not [int]::TryParse([string]$ResourceLimits[$name],[ref]$value) -or
           $value -lt 0 -or $value -gt $capacities[$name]) {
            throw "Invalid device resource limit: $name"
        }
        $ResourceLimits[$name]=$value
    }
}
$failures=@()
$rows=foreach($name in $baseline.Keys) {
    $required=$true
    $pass=if($name -in 'SWNS','HWNS') {$candidate[$name] -ge 0}
          elseif($name -in 'STNS','HTNS','setup_violations','hold_violations') {$candidate[$name] -eq 0}
          elseif($ResourceLimits.ContainsKey($name)) {$candidate[$name] -le $ResourceLimits[$name]}
          elseif($ResourceLimits.Count) {$required=$false; $null}
          else {$candidate[$name] -le $baseline[$name]}
    if($required -and -not $pass) {$failures+=$name}
    [pscustomobject]@{metric=$name;baseline=$baseline[$name];candidate=$candidate[$name];
        delta=($candidate[$name]-$baseline[$name]);required=$required;passed=$pass}
}
$result=[ordered]@{
    status=$(if($failures.Count){'failed'}else{'passed'})
    policy=$(if($ResourceLimits.Count){'explicit_resource_limits'}else{'no_increase'})
    resource_limits=$ResourceLimits
    baseline=$baselineRoot;candidate=$candidateRoot;metrics=@($rows);failed_metrics=$failures
}
$destination=Resolve-Input $OutputPath
if(-not $destination.StartsWith($root+[IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) {throw 'Comparison output must stay inside workspace'}
New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $destination -Encoding UTF8
$rows | Format-Table -AutoSize
if($failures.Count) {throw "Physical acceptance failed: $($failures -join ', ')"}
Write-Output "AE_AWB_PHYSICAL_COMPARISON_PASS $destination"
