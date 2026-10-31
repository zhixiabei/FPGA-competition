param(
    [ValidateSet('Portable','Vendor','Both')][string]$Mode='Both',
    [int]$TestGroup=0,
    [string]$RtlSource='',
    [string]$OutputDir='',
    [int]$TimeoutSeconds=300,
    [string]$ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string]$TdSimLib='D:\TD\sim_release\ph1p'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($TestGroup -lt 0 -or $TestGroup -gt 3){throw 'TestGroup must be 0..3.'}
if($TimeoutSeconds -lt 1){throw 'TimeoutSeconds must be positive.'}
$root=Split-Path -Parent $PSScriptRoot
$work=if($OutputDir){[IO.Path]::GetFullPath($OutputDir)}else{
    Join-Path $env:TEMP ('anlogic_color_repair_'+[guid]::NewGuid().ToString('N'))
}
if(Test-Path -LiteralPath $work){throw "Output already exists: $work"}
New-Item -ItemType Directory -Path $work | Out-Null
$rtl=if($RtlSource){$RtlSource}else{Join-Path $root 'user_source/hdl_source/isp/red_target_detect_96.v'}
Copy-Item -LiteralPath $rtl -Destination (Join-Path $work 'red_target_detect_96.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_single_color_repair.sv') -Destination $work
Write-Output "Simulation output: $work"
$manifest=[ordered]@{Test='SINGLE_COLOR_REPAIR';Status='STARTED';TestGroup=$TestGroup;RtlSHA256=(Get-FileHash -LiteralPath (Join-Path $work 'red_target_detect_96.v')).Hash;TestbenchSHA256=(Get-FileHash -LiteralPath (Join-Path $work 'tb_single_color_repair.sv')).Hash;Variants=@()}
$manifestPath=Join-Path $work 'validation_manifest.json'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
foreach($variant in $(if($Mode -eq 'Both'){@('Portable','Vendor')}else{@($Mode)})){
    $stem=$variant.ToLowerInvariant()
    $defines=if($variant -eq 'Portable'){'+define+RED_MULTI_PORTABLE_RAM'}else{''}
    $primitives='';$vendorTop=''
    if($variant -eq 'Vendor'){
        foreach($name in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')){
            Copy-Item -LiteralPath (Join-Path $TdSimLib $name) -Destination $work
        }
        $primitives='ph1p_logic_eram.v ph1p_phy_gsr.v';$vendorTop='work.PH1P_PHY_GSR'
    }
    $script=@"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {[file exists work]} {vdel -all -lib work}
vlib work
vlog -sv $defines red_target_detect_96.v tb_single_color_repair.sv $primitives
vsim -t ps -gTEST_GROUP=$TestGroup work.tb_single_color_repair $vendorTop
run -all
quit -code 0 -force
"@
    [IO.File]::WriteAllText((Join-Path $work "$stem.do"),$script,[Text.UTF8Encoding]::new($false))
    $log=Join-Path $work "${stem}_console.log";$err=Join-Path $work "${stem}_stderr.log"
    $process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') -WindowStyle Hidden -PassThru `
        -ArgumentList "-c -do $stem.do -l ${stem}_transcript.log" -WorkingDirectory $work `
        -RedirectStandardOutput $log -RedirectStandardError $err
    $handle=$process.Handle
    if(-not $process.WaitForExit($TimeoutSeconds*1000)){
        Stop-Process -Id $process.Id
        $manifest.Status='TIMEOUT'
        $manifest.Variants+=@{Mode=$variant;Passed=$false;Console=$log;Marker='TIMEOUT'}
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        throw "Simulation timeout: $log"
    }
    $process.WaitForExit();$process.Refresh()
    $output=[IO.File]::ReadAllText($log)+[IO.File]::ReadAllText($err)
    $pass=[regex]::Match($output,'(?m)^\s*(?:#\s*)?SINGLE_COLOR_REPAIR_PASS\b.*$')
    $ok=$process.ExitCode -eq 0 -and $pass.Success -and $output -notmatch '(?im)\*\*\s*(Fatal|Error)'
    $manifest.Variants+=@{Mode=$variant;Passed=$ok;ExitCode=$process.ExitCode;Console=$log;Marker=$pass.Value.Trim()}
    $manifest.Status=if($ok){'RUNNING'}else{'FAIL'}
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if(-not $ok){throw "Repair regression failed: $log"}
    $pass.Value.Trim()
}
$manifest.Status='PASS'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Output "SINGLE_COLOR_REPAIR_REGRESSION_PASS manifest=$manifestPath"
