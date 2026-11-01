param(
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $ReferenceRef='9d1735febb37f6f23c2474831508e1a24308f9c8',
    [string] $VendorDirectory='D:\TD\sim_release\ph1p'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $env:TEMP ('anlogic_bridge_routing_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$reference=& git -C $root show ($ReferenceRef+':user_source/hdl_source/target_frame_bridge.v')
if($LASTEXITCODE -ne 0) {throw 'Cannot read the pre-routing bridge reference'}
$referenceText=($reference -join "`n")+"`n"
$referenceText=[regex]::Replace($referenceText,'\btarget_frame_bridge\b','target_frame_bridge_reference')
$referenceText=[regex]::Replace($referenceText,'\bvideo_ddr_write_progress\b','video_ddr_write_progress_reference')
[IO.File]::WriteAllText((Join-Path $work 'reference.v'),$referenceText,[Text.UTF8Encoding]::new($false))
$sourcePaths=@(
    'user_source/hdl_source/target_frame_bridge.v',
    'sim/tb_target_frame_bridge.sv',
    'sim/tb_target_frame_bridge_slot_writes.sv',
    'sim/tb_target_frame_bridge_single_payload.sv'
)
foreach($relative in $sourcePaths) {
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $work
}
$sources=(@('reference.v')+@($sourcePaths | ForEach-Object {Split-Path -Leaf $_})) -join ' '
$tops=@('tb_target_frame_bridge','tb_target_frame_bridge_slot_writes','tb_target_frame_bridge_single_payload')
Write-Output "Bridge routing simulation: $work"
foreach($variant in @('portable','vendor')) {
    $models=if($variant -eq 'portable') {
        '{'+(Join-Path $root 'sim/reference/ph1p_logic_dram_asym_sim.v').Replace('\','/')+'}'
    } else {
        '{'+(Join-Path $VendorDirectory 'ph1p_logic_dram.v').Replace('\','/')+'} {'+
        (Join-Path $VendorDirectory 'ph1p_phy_gsr.v').Replace('\','/')+'}'
    }
    $extraTop=if($variant -eq 'vendor') {"$variant.PH1P_PHY_GSR"} else {''}
    $script="onerror {quit -code 1 -force}`nonbreak {resume}`nvlib $variant`n"
    $script+="vlog -work $variant -sv +define+BRIDGE_ROUTING_REFERENCE $models $sources`n"
    foreach($top in $tops) {
        $script+="vsim -onfinish stop -L $variant -t ps $variant.$top $extraTop`nrun -all`nquit -sim`n"
    }
    $script+="quit -code 0 -force`n"
    $doFile=$variant+'.do'
    [IO.File]::WriteAllText((Join-Path $work $doFile),$script,[Text.UTF8Encoding]::new($false))
    $console=Join-Path $work ($variant+'.log')
    $process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
        -ArgumentList @('-c','-do',$doFile,'-l',($variant+'.transcript.log')) `
        -WorkingDirectory $work -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $console -RedirectStandardError (Join-Path $work ($variant+'.stderr.log'))
    $nativeHandle=$process.Handle
    $deadline=[datetime]::UtcNow.AddMinutes(5)
    while(-not $process.WaitForExit(1000)) {
        if([datetime]::UtcNow -gt $deadline) {
            Stop-Process -Id $process.Id -Force
            throw "Bridge simulation timed out: $console"
        }
    }
    $process.WaitForExit()
    $process.Refresh()
    $text=[IO.File]::ReadAllText($console)
    if($process.ExitCode -ne 0 -or $text -match '(?im)^\s*(?:#\s*)?\*\*\s+(Fatal|Error)\b') {
        throw "Bridge simulation failed: $console"
    }
    foreach($marker in @('TARGET_FRAME_BRIDGE_PASS','TARGET_FRAME_BRIDGE_SLOT_WRITES_PASS',
        'TARGET_FRAME_BRIDGE_SINGLE_PAYLOAD_PASS','TARGET_FRAME_BRIDGE_ROUTING_EQUIVALENCE_PASS')) {
        $matches=[regex]::Matches($text,'(?m)^\s*#\s*'+$marker+'\b.*$')
        if($matches.Count -ne 1) {throw "Missing/duplicate $marker in $console"}
        Write-Output ($variant+': '+$matches[0].Value.Trim())
    }
}
