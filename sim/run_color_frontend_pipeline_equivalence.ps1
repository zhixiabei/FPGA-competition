param(
    [ValidateSet('Portable','Vendor','Both')]
    [string] $Mode='Both',
    [int[]] $Delta=@(0,6,256,257,511),
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib='D:\TD\sim_release\ph1p'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$baseline=Join-Path $root 'build\timing_resource_repair_20261027\baseline'
$work=Join-Path $env:TEMP ('anlogic_color_frontend_eq_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$relative='user_source/hdl_source/isp/red_target_detect_96.v'
$expected=@(Import-Csv -LiteralPath (Join-Path $baseline 'source_sha256.csv') |
    Where-Object {$_.Path -eq $relative})
$frozenPath=Join-Path $baseline $relative
if($expected.Count -ne 1 -or
    (Get-FileHash -LiteralPath $frozenPath -Algorithm SHA256).Hash -ne $expected[0].Hash) {
    throw 'Frozen reference does not match its baseline manifest.'
}
Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $work
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_color_frontend_pipeline_equivalence.sv') `
    -Destination $work
$frozen=[IO.File]::ReadAllText($frozenPath)
$moduleNames=@([regex]::Matches($frozen,'(?m)^module\s+(\w+)') |
    ForEach-Object {$_.Groups[1].Value})
foreach($name in $moduleNames) {
    $frozen=[regex]::Replace($frozen,'\b'+[regex]::Escape($name)+'\b',$name+'_frozen')
}
[IO.File]::WriteAllText((Join-Path $work 'red_target_detect_96_frozen.v'),
    $frozen,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $work"
$sourceHashes=@(Get-ChildItem -LiteralPath $work -File | ForEach-Object {
    [pscustomobject]@{File=$_.Name;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
})
$sourceHashes | Export-Csv -LiteralPath (Join-Path $work 'source_sha256.csv') -NoTypeInformation
foreach($variant in $(if($Mode -eq 'Both') {@('Portable','Vendor')} else {@($Mode)})) {
    $stem=$variant.ToLowerInvariant()
    $defines=if($variant -eq 'Portable') {'+define+RED_MULTI_PORTABLE_RAM'} else {''}
    $primitives='';$vendorTop=''
    if($variant -eq 'Vendor') {
        foreach($name in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')) {
            Copy-Item -LiteralPath (Join-Path $TdSimLib $name) -Destination $work
        }
        $primitives='ph1p_logic_eram.v ph1p_phy_gsr.v';$vendorTop='work.PH1P_PHY_GSR'
    }
    $runs=foreach($value in $Delta) {
        if($value -lt 0 -or $value -gt 511) {throw 'Delta must be within 0..511.'}
        "vsim -onfinish stop -t ps -gDELTA=$value work.tb_color_frontend_pipeline_equivalence $vendorTop`nrun -all`nquit -sim"
    }
    $script=@"
onerror {quit -code 1 -force}
onbreak {resume}
if {[file exists work]} {vdel -all -lib work}
vlib work
vlog -sv $defines red_target_detect_96.v red_target_detect_96_frozen.v tb_color_frontend_pipeline_equivalence.sv $primitives
$($runs -join "`n")
quit -code 0 -force
"@
    [IO.File]::WriteAllText((Join-Path $work ($stem+'.do')),$script,[Text.UTF8Encoding]::new($false))
    $log=Join-Path $work ($stem+'_console.log')
    $err=Join-Path $work ($stem+'_stderr.log')
    $process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') -WindowStyle Hidden `
        -ArgumentList "-c -do $stem.do -l ${stem}_transcript.log" -WorkingDirectory $work `
        -RedirectStandardOutput $log -RedirectStandardError $err -PassThru
    $processHandle=$process.Handle
    if(-not $process.WaitForExit(180000)) {
        Stop-Process -Id $process.Id
        throw "Frontend differential simulation timed out: $log"
    }
    $process.WaitForExit()
    $text=[IO.File]::ReadAllText($log)+[IO.File]::ReadAllText($err)
    $pass='(?m)^\s*(?:#\s*)?COLOR_FRONTEND_EQUIVALENCE_PASS\b.*$'
    if($process.ExitCode -ne 0 -or
        $text -match '(?im)^\s*(?:#\s*)?\*\*\s*(Fatal|Error)' -or
        [regex]::Matches($text,$pass).Count -ne $Delta.Count) {
        throw "Frontend differential simulation failed: $log"
    }
    [regex]::Matches($text,$pass) | ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
}
Write-Output "COLOR_FRONTEND_REGRESSION_PASS mode=$Mode"
