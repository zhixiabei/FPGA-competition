param(
    [ValidateSet('Portable','Vendor','Both')][string]$Mode='Both',
    [string]$ReferenceRef='8dc675d86bb4ed0de378a35d1faf6a7de8476f12',
    [string]$ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string]$TdSimLib='D:\TD\sim_release\ph1p',
    [int]$TimeoutSeconds=600
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $env:TEMP ('anlogic_detector_row_routing_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$reference=& git -C $root show ($ReferenceRef+':user_source/hdl_source/isp/red_target_detect_96.v')
if($LASTEXITCODE -ne 0){throw 'Cannot read detector routing reference'}
$referenceText=($reference -join "`n")+"`n"
$moduleNames=[regex]::Matches($referenceText,'(?m)^module\s+(\w+)\b') |
    ForEach-Object {$_.Groups[1].Value}
foreach($moduleName in $moduleNames){
    $referenceText=[regex]::Replace($referenceText,'\b'+[regex]::Escape($moduleName)+'\b',($moduleName+'_reference'))
}
[IO.File]::WriteAllText((Join-Path $work 'reference.v'),$referenceText,[Text.UTF8Encoding]::new($false))
foreach($relative in @('user_source/hdl_source/isp/red_target_detect_96.v',
    'sim/tb_detector_row_routing.sv','sim/tb_single_color_shape.sv')){
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $work
}
$manifest=[ordered]@{
    Test='DETECTOR_ROW_ROUTING';Status='STARTED';ReferenceRef=$ReferenceRef;
    StartedAt=(Get-Date).ToString('o');
    SourceHashes=@(Get-ChildItem -LiteralPath $work -File | ForEach-Object {
        @{File=$_.Name;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    });Variants=@()
}
$manifestPath=Join-Path $work 'validation_manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Output "Detector routing simulation: $work"
foreach($variant in $(if($Mode -eq 'Both'){@('Portable','Vendor')}else{@($Mode)})){
    $stem=$variant.ToLowerInvariant()
    $defines='+define+DETECTOR_ROUTING_REFERENCE'
    $models='';$extraTop=''
    if($variant -eq 'Portable'){$defines+=' +define+RED_MULTI_PORTABLE_RAM'}else{
        foreach($name in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')){
            Copy-Item -LiteralPath (Join-Path $TdSimLib $name) -Destination $work
        }
        $models='ph1p_logic_eram.v ph1p_phy_gsr.v';$extraTop='work.PH1P_PHY_GSR'
    }
    $script=@"
onerror {quit -code 1 -force}
onbreak {resume}
if {[file exists work]} {vdel -all -lib work}
vlib work
vlog -sv $defines reference.v red_target_detect_96.v tb_detector_row_routing.sv tb_single_color_shape.sv $models
vsim -onfinish stop -t ps work.tb_detector_row_routing $extraTop
run -all
quit -sim
vsim -onfinish stop -t ps work.tb_single_color_shape $extraTop
run -all
quit -code 0 -force
"@
    [IO.File]::WriteAllText((Join-Path $work ($stem+'.do')),$script,[Text.UTF8Encoding]::new($false))
    $log=Join-Path $work ($stem+'_console.log');$err=Join-Path $work ($stem+'_stderr.log')
    $process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') -WindowStyle Hidden -PassThru `
        -ArgumentList ('-c -do '+$stem+'.do -l '+$stem+'_transcript.log') -WorkingDirectory $work `
        -RedirectStandardOutput $log -RedirectStandardError $err
    $nativeHandle=$process.Handle
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while(-not $process.WaitForExit(1000)){
        if([datetime]::UtcNow -gt $deadline){
            Stop-Process -Id $process.Id
            $manifest.Status='TIMEOUT'
            $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            throw "Detector routing simulation timed out: $log"
        }
    }
    $process.WaitForExit();$process.Refresh()
    $output=[IO.File]::ReadAllText($log)+[IO.File]::ReadAllText($err)
    $ok=$process.ExitCode -eq 0 -and $output -notmatch '(?im)\*\*\s*(Fatal|Error)'
    $markers=@()
    foreach($marker in @('DETECTOR_ROW_ROUTING_EQUIVALENCE_PASS',
        'DETECTOR_ROUTING_OUTPUT_EQUIVALENCE_PASS','SINGLE_COLOR_SHAPE_PASS')){
        $matches=[regex]::Matches($output,'(?m)^\s*(?:#\s*)?'+$marker+'\b.*$')
        if($matches.Count -ne 1){$ok=$false}else{$markers+=$matches[0].Value.Trim()}
    }
    if([regex]::Matches($output,'(?m)^\s*(?:#\s*)?DETECTOR_ROW_ROUTING_CASE_PASS\b').Count -ne 2){$ok=$false}
    $manifest.Variants+=@{Mode=$variant;Passed=$ok;ExitCode=$process.ExitCode;Console=$log;Markers=$markers}
    $manifest.Status=if($ok){'RUNNING'}else{'FAIL'}
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if(-not $ok){throw "Detector routing regression failed: $log"}
    $markers | ForEach-Object {Write-Output ($variant+': '+$_)}
}
$manifest.Status='PASS';$manifest.FinishedAt=(Get-Date).ToString('o')
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Output "DETECTOR_ROW_ROUTING_REGRESSION_PASS manifest=$manifestPath"
