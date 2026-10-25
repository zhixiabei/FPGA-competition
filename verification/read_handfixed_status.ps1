param(
    [switch]$WinUsb,
    [string]$Port='',
    [string]$UsbSerial='',
    [ValidateRange(1,3600)][int]$Samples=1,
    [ValidateRange(1,60)][int]$IntervalSeconds=2,
    [string]$ResponseFile='',
    [switch]$Fruit,
    [string]$Project=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($Fruit -and -not $Project){$Project='build/fruit/td'}
$fruitClassNames=@('APPLE','BANANA','GRAPE','ORANGE','STRAWBERRY')
if($Project) {
    if(-not $Fruit){throw '-Project requires -Fruit.'}
    $root=Split-Path -Parent $PSScriptRoot
    $projectPath=if([IO.Path]::IsPathRooted($Project)){$Project}else{Join-Path $root $Project}
    $config=Get-Content -LiteralPath (Join-Path $projectPath 'candidate_config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($config.design -ne 'five_fruit_fixed_roi' -or $config.status_magic -ne 'FRU1' -or
       @($config.classes).Count -ne 5 -or @($config.classes | Select-Object -Unique).Count -ne 5) {
        throw 'Expected a five-class fruit project.'
    }
    $fruitClassNames=@($config.classes | ForEach-Object { $_.ToUpperInvariant() })
}
Add-Type -TypeDefinition @'
public static class HandFixedStatusCrc {
    public static uint Compute(byte[] b, int n) {
        uint c=0xffffffff;
        for(int i=0;i<n;i++) {
            c^=b[i];
            for(int k=0;k<8;k++) c=(c&1)!=0 ? (c>>1)^0xedb88320 : c>>1;
        }
        return ~c;
    }
}
'@
function ConvertFrom-HandFixedStatus([byte[]]$Bytes) {
    $magic=if($Fruit){'FRU1'}else{'HFX1'}
    if($Bytes.Length -ne 36 -or [Text.Encoding]::ASCII.GetString($Bytes,0,4) -ne $magic -or $Bytes[4] -ne 1) {
        throw "Unrecognized status response. Expected the $magic fixed-region bitstream."
    }
    if([HandFixedStatusCrc]::Compute($Bytes,32) -ne [BitConverter]::ToUInt32($Bytes,32)) {
        throw 'Status CRC32 mismatch. Retry the query; this response is not valid.'
    }
    $flags=$Bytes[5]
    $modelReady=($flags -band 2) -ne 0
    $snapshotBusy=($flags -band 4) -ne 0
    $executorBusy=($flags -band 16) -ne 0
    $memoryError=($flags -band 32) -ne 0
    $count=[BitConverter]::ToUInt16($Bytes,8)
    $classId=$Bytes[6] -band 7
    $classNames=if($Fruit){@('UNKNOWN')+$fruitClassNames}else{@('NOTHING','PEACE','PUNCH','STOP')}
    $logitCount=if($Fruit){5}else{3}
    $cycleOffset=if($Fruit){22}else{18}
    [pscustomobject][ordered]@{
        calibrated=($flags -band 1) -ne 0
        model_ready=$modelReady
        snapshot_busy=$snapshotBusy
        snapshot_failed=($flags -band 8) -ne 0
        executor_busy=$executorBusy
        memory_error=$memoryError
        temporal_confirmation=($flags -band 64) -ne 0
        manual_key4_control=($Bytes[6] -band 128) -ne 0
        recognition_enabled=if($Bytes[6] -band 128){($Bytes[6] -band 64) -ne 0}else{$true}
        old_work_draining=($Bytes[6] -band 32) -ne 0
        background_control=($Bytes[6] -band 16) -ne 0
        background_ready=($Bytes[6] -band 8) -ne 0
        core_fault=($flags -band 128) -ne 0
        capture_failures=$Bytes[7]
        completed_results=$count
        result_frame=[BitConverter]::ToUInt16($Bytes,10)
        last_display=if(($count -or ($Bytes[6] -band 128)) -and $classId -ge 1 -and $classId -le $classNames.Count){$classNames[$classId-1]}else{$null}
        logits_note=if($flags -band 64){'Raw CNN logits: the confirmed display label can differ; paused or flat ROI retains older logits'}else{'Logits retain the last CNN result when a flat ROI skips classification'}
        logits=@(0..($logitCount-1) | ForEach-Object {[BitConverter]::ToInt16($Bytes,12+2*$_)})
        processing_cycles=[BitConverter]::ToUInt32($Bytes,$cycleOffset)
        processing_ms=[BitConverter]::ToUInt32($Bytes,$cycleOffset)*0.000015
        cumulative_core_cycles=[BitConverter]::ToUInt32($Bytes,$cycleOffset+4)
        cumulative_mac_issue_cycles=if($Fruit){[BitConverter]::ToUInt16($Bytes,30)}else{[BitConverter]::ToUInt32($Bytes,26)}
        cumulative_core_wait_cycles_mod65536=if($Fruit){$null}else{[BitConverter]::ToUInt16($Bytes,30)}
    }
}
if($ResponseFile) {
    ConvertFrom-HandFixedStatus ([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ResponseFile))) | ConvertTo-Json -Depth 4
    return
}
if($WinUsb -and $Port){throw 'Choose -WinUsb or -Port.'}
$serial=$null
try {
    if($WinUsb) {
        Add-Type -Path (Join-Path $PSScriptRoot 'FtdiWinUsbTransport.cs')
        $serial=[FtdiWinUsbTransport]::Open($UsbSerial,921600)
    } elseif($Port) {
        $serial=[IO.Ports.SerialPort]::new($Port,921600,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
        $serial.ReadTimeout=5000;$serial.WriteTimeout=5000
        $serial.DtrEnable=$false;$serial.RtsEnable=$false
        $serial.Open();$serial.DiscardInBuffer()
    } else {throw 'Use -WinUsb for board 0403:6042, or -Port for a hardware UART.'}
    for($sample=0;$sample -lt $Samples;$sample++) {
        [byte[]]$request=82,49,56,83
        $serial.Write($request,0,4)
        [byte[]]$response=New-Object byte[] 36
        try {for($i=0;$i -lt 36;$i++){$response[$i]=[byte]$serial.ReadByte()}}
        catch [TimeoutException] {throw 'No runtime status reply. Program the fixed-region CNN bitstream before querying its status. This query does not load or clear weights.'}
        ConvertFrom-HandFixedStatus $response | ConvertTo-Json -Depth 4 -Compress
        if($sample+1 -lt $Samples){Start-Sleep -Seconds $IntervalSeconds}
    }
} finally {if($null -ne $serial){$serial.Dispose()}}
