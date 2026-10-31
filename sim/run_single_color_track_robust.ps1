param(
    [ValidateSet('Portable','Vendor','Both')][string] $Mode='Portable',
    [int] $Width=320,
    [int] $Height=240,
    [int] $TimeoutSeconds=300,
    [string] $RtlSource='',
    [string] $OutputDir='',
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib='D:\TD\sim_release\ph1p'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($Width -lt 320 -or $Height -lt 240 -or $Width%4 -ne 0) {
    throw 'Robust tracking patterns require Width>=320, Height>=240 and Width divisible by four.'
}
if($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
foreach($tool in @('vsim.exe','vlog.exe')) {
    if(-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$projectRoot=Split-Path -Parent $PSScriptRoot
$simulationDir=if($OutputDir) {[IO.Path]::GetFullPath($OutputDir)} else {
    Join-Path $env:TEMP ('anlogic_single_color_track_robust_'+[guid]::NewGuid().ToString('N'))
}
if(Test-Path -LiteralPath $simulationDir) {
    if(@(Get-ChildItem -LiteralPath $simulationDir -Force).Count -ne 0) {
        throw "OutputDir must be new or empty: $simulationDir"
    }
} else {
    New-Item -ItemType Directory -Path $simulationDir | Out-Null
}
$selectedRtl=if($RtlSource) {$RtlSource} else {
    Join-Path $projectRoot 'user_source\hdl_source\isp\red_target_detect_96.v'
}
Copy-Item -LiteralPath $selectedRtl -Destination (Join-Path $simulationDir 'red_target_detect_96.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_single_color_track_robust.sv') -Destination $simulationDir
$variants=if($Mode -eq 'Both') {@('Portable','Vendor')} else {@($Mode)}
if($variants -contains 'Vendor') {
    foreach($primitive in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')) {
        Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $simulationDir
    }
}
$sourceHashes=foreach($snapshot in Get-ChildItem -LiteralPath $simulationDir -File) {
    [pscustomobject]@{
        File=$snapshot.Name
        SHA256=(Get-FileHash -LiteralPath $snapshot.FullName -Algorithm SHA256).Hash
    }
}
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$manifest=[ordered]@{
    Test='SINGLE_COLOR_TRACK_ROBUST'
    Status='STARTED'
    StartedAt=(Get-Date).ToString('o')
    RequestedMode=$Mode
    Width=$Width
    Height=$Height
    RtlSource=(Resolve-Path -LiteralPath $selectedRtl).Path
    Contract='RGB public IO; MULTI_ENABLE=0; SINGLE_SHAPE_ENABLE=1; one contour/track; tightened red; expanded raw-track window; raw association and smoothed display; two-frame confirm/two-miss hold'
    SourceHashes=$sourceHashes
    Variants=@()
}
$manifestPath=Join-Path $simulationDir 'validation_manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Output "Simulation output: $simulationDir"
foreach($variant in $variants) {
    $stem=$variant.ToLowerInvariant()
    $options=if($variant -eq 'Portable') {'+define+RED_MULTI_PORTABLE_RAM'} else {''}
    $vendorSources=if($variant -eq 'Vendor') {'ph1p_logic_eram.v ph1p_phy_gsr.v'} else {''}
    $vendorTop=if($variant -eq 'Vendor') {'work.PH1P_PHY_GSR'} else {''}
    $script=@"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {[file exists work]} {vdel -all -lib work}
vlib work
vlog -sv $options red_target_detect_96.v tb_single_color_track_robust.sv $vendorSources
vsim -t ps -gW=$Width -gH=$Height work.tb_single_color_track_robust $vendorTop
run -all
quit -code 0 -force
"@
    [IO.File]::WriteAllText((Join-Path $simulationDir ($stem+'_run.do')),$script,[Text.UTF8Encoding]::new($false))
    $consolePath=Join-Path $simulationDir ($stem+'_console.log')
    $errorPath=Join-Path $simulationDir ($stem+'_stderr.log')
    $variantStarted=(Get-Date).ToString('o')
    $process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
        -ArgumentList ('-c -do '+$stem+'_run.do -l '+$stem+'_transcript.log') `
        -WorkingDirectory $simulationDir -WindowStyle Hidden `
        -RedirectStandardOutput $consolePath -RedirectStandardError $errorPath -PassThru
    $nativeHandle=$process.Handle
    if(-not $process.WaitForExit($TimeoutSeconds*1000)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        $manifest.Status='TIMEOUT'
        $manifest.Variants+=@{Mode=$variant;Status='TIMEOUT';Console=$consolePath;StartedAt=$variantStarted}
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        throw "$variant robust single color regression timed out; see $consolePath"
    }
    $process.WaitForExit(); $process.Refresh()
    $console=[IO.File]::ReadAllText($consolePath)+[IO.File]::ReadAllText($errorPath)
    $passPattern='(?m)^\s*(?:#\s*)?SINGLE_COLOR_TRACK_ROBUST_PASS\b.*$'
    $failurePattern='(?im)^\s*(?:#\s*)?(?:\*\*\s*(?:Fatal|Error)\b|(?:Fatal|ERROR):)'
    $requiredMarkers=@(
        'THRESHOLD','ISOLATION','SMOOTH','REACQUIRE','SIZE_GATE','HOLE','U_SHAPE','RESYNC','ABORT_BURST'
    )
    $missingMarkers=@($requiredMarkers | Where-Object {
        $console -notmatch ('(?m)^\s*(?:#\s*)?SINGLE_COLOR_TRACK_'+$_+'_PASS\b')
    })
    $passed=$process.ExitCode -eq 0 -and $console -notmatch $failurePattern -and
        [regex]::Matches($console,$passPattern).Count -eq 1 -and $missingMarkers.Count -eq 0
    $status=if($passed) {'PASS'} else {'FAIL'}
    $passLine=([regex]::Match($console,$passPattern).Value.Trim() -replace '^#\s*','')
    $manifest.Variants+=@{
        Mode=$variant;Status=$status;ExitCode=$process.ExitCode
        StartedAt=$variantStarted;FinishedAt=(Get-Date).ToString('o')
        Console=$consolePath;PassMarker=$passLine;MissingMarkers=$missingMarkers
    }
    $manifest.Status=if($passed) {'RUNNING'} else {'FAIL'}
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if(-not $passed) { throw "$variant robust single color regression failed; see $consolePath" }
    $passLine
}
$manifest.Status='PASS'
$manifest.FinishedAt=(Get-Date).ToString('o')
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Output "SINGLE_COLOR_TRACK_ROBUST_REGRESSION_PASS mode=$Mode manifest=$manifestPath"
