param(
    [ValidateSet('Portable','Vendor','Both')][string] $Mode='Both',
    [string] $RtlSource='',
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib='D:\TD\sim_release\ph1p'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
$simulationDir=Join-Path $env:TEMP ('anlogic_single_target_switch_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$selectedRtl=if($RtlSource) {$RtlSource} else {
    Join-Path $projectRoot 'user_source\hdl_source\isp\red_target_detect_96.v'
}
Copy-Item -LiteralPath $selectedRtl -Destination (Join-Path $simulationDir 'red_target_detect_96.v')
foreach($relative in @(
    'user_source\hdl_source\isp\motion_target_detect_96.v',
    'user_source\hdl_source\isp\target_detect_switch_96.v',
    'sim\tb_single_target_switch.sv'
)) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $simulationDir
}
$variants=if($Mode -eq 'Both') {@('Portable','Vendor')} else {@($Mode)}
if($variants -contains 'Vendor') {
    foreach($primitive in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')) {
        Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $simulationDir
    }
}
Write-Output "Simulation output: $simulationDir"
foreach($variant in $variants) {
    $stem=$variant.ToLowerInvariant()
    $options=if($variant -eq 'Portable') {
        '+define+RED_MULTI_PORTABLE_RAM +define+MOTION_PORTABLE_RAM'
    } else {''}
    $vendorSources=if($variant -eq 'Vendor') {'ph1p_logic_eram.v ph1p_phy_gsr.v'} else {''}
    $vendorTop=if($variant -eq 'Vendor') {'work.PH1P_PHY_GSR'} else {''}
    $script=@"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {[file exists work]} {vdel -all -lib work}
vlib work
vlog -sv $options red_target_detect_96.v motion_target_detect_96.v target_detect_switch_96.v tb_single_target_switch.sv $vendorSources
vsim -t ps work.tb_single_target_switch $vendorTop
run -all
quit -code 0 -force
"@
    $scriptPath=Join-Path $simulationDir ($stem+'_run.do')
    [IO.File]::WriteAllText($scriptPath,$script,[Text.UTF8Encoding]::new($false))
    $consolePath=Join-Path $simulationDir ($stem+'_console.log')
    $errorPath=Join-Path $simulationDir ($stem+'_stderr.log')
    $process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
        -ArgumentList ('-c -do '+$stem+'_run.do -l '+$stem+'_transcript.log') `
        -WorkingDirectory $simulationDir -WindowStyle Hidden `
        -RedirectStandardOutput $consolePath -RedirectStandardError $errorPath -PassThru
    $nativeHandle=$process.Handle
    if(-not $process.WaitForExit(240000)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        throw "$variant single switch test timed out: $consolePath"
    }
    $process.WaitForExit();$process.Refresh()
    $console=[IO.File]::ReadAllText($consolePath)+[IO.File]::ReadAllText($errorPath)
    $passPattern='(?m)^\s*(?:#\s*)?SINGLE_TARGET_SWITCH_PASS\b.*$'
    if($process.ExitCode -ne 0 -or
       $console -match '(?im)^\s*(?:#\s*)?(?:\*\*\s*(?:Fatal|Error)\b|(?:Fatal|ERROR):)' -or
       [regex]::Matches($console,$passPattern).Count -ne 1) {
        throw "$variant single switch regression failed: $consolePath"
    }
    ([regex]::Match($console,$passPattern).Value.Trim() -replace '^#\s*','')+" variant=$variant"
}
Get-ChildItem -LiteralPath $simulationDir -File |
    Where-Object {$_.Extension -in @('.v','.sv')} |
    Get-FileHash -Algorithm SHA256 |
    Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "SINGLE_TARGET_SWITCH_REGRESSION_PASS mode=$Mode"
