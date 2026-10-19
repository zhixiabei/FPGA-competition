param(
    [ValidateSet('Portable','Vendor','Both')][string] $Mode='Portable',
    [string] $RtlSource='',
    [switch] $ProbeOnly,
    [int] $TimeoutSeconds=240,
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib='D:\TD\sim_release\ph1p'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $env:TEMP ('anlogic_shape_rotation_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$source=if($RtlSource) {$RtlSource} else {Join-Path $root 'user_source/hdl_source/isp/red_target_detect_96.v'}
Copy-Item -LiteralPath $source -Destination (Join-Path $work 'red_target_detect_96.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_color_shape_rotation.sv') -Destination $work
@('red_target_detect_96.v','tb_color_shape_rotation.sv') | ForEach-Object {
    [pscustomobject]@{File=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $work $_) -Algorithm SHA256).Hash}
} | Export-Csv -LiteralPath (Join-Path $work 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $work"
$probeMode=[int]$ProbeOnly.IsPresent
$variants=if($Mode -eq 'Both') {@('Portable','Vendor')} else {@($Mode)}
foreach($variant in $variants) {
    $stem=$variant.ToLowerInvariant()
    $options=if($variant -eq 'Portable') {'+define+RED_MULTI_PORTABLE_RAM'} else {''}
    $vendorSources=''
    $vendorTop=''
    if($variant -eq 'Vendor') {
        foreach($primitive in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')) {
            Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $work
        }
        $vendorSources='ph1p_logic_eram.v ph1p_phy_gsr.v'
        $vendorTop='work.PH1P_PHY_GSR'
    }
    $script=@"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {[file exists work]} {vdel -all -lib work}
vlib work
vlog -sv $options red_target_detect_96.v tb_color_shape_rotation.sv $vendorSources
vsim -t ps -gPROBE_ONLY=$probeMode work.tb_color_shape_rotation $vendorTop
run -all
quit -code 0 -force
"@
    [IO.File]::WriteAllText((Join-Path $work ($stem+'_run.do')),$script,[Text.UTF8Encoding]::new($false))
    $log=Join-Path $work ($stem+'_console.log')
    $stderr=Join-Path $work ($stem+'_stderr.log')
    $process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
        -ArgumentList ('-c -do '+$stem+'_run.do -l '+$stem+'_transcript.log') `
        -WorkingDirectory $work -WindowStyle Hidden -RedirectStandardOutput $log `
        -RedirectStandardError $stderr -PassThru
    if(-not $process.WaitForExit($TimeoutSeconds*1000)) {
        Stop-Process -Id $process.Id
        throw "Rotation regression timed out: $log"
    }
    $process.WaitForExit();$process.Refresh()
    $output=[IO.File]::ReadAllText($log)+[IO.File]::ReadAllText($stderr)
    $pass='(?m)^\s*(?:#\s*)?COLOR_SHAPE_ROTATION_PASS\b.*$'
    if($process.ExitCode -ne 0 -or $output -match '(?im)^\s*(?:#\s*)?\*\* (Fatal|Error)' -or
       [regex]::Matches($output,$pass).Count -ne 1) {throw "Rotation regression failed: $log"}
    [regex]::Matches($output,'(?m)^\s*(?:#\s*)?ROTATION_PUBLISHED\b.*$') | ForEach-Object {
        $_.Value.Trim() -replace '^#\s*',''
    }
    ([regex]::Match($output,$pass).Value.Trim() -replace '^#\s*','')
}
Write-Output "COLOR_SHAPE_ROTATION_REGRESSION_PASS mode=$Mode probe_only=$probeMode"
