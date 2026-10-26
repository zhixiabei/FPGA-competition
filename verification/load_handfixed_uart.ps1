param(
    [string]$Port='',
    [int]$Baud=921600,
    [string]$Model='build/gesture/weights/model.bin',
    [string]$Manifest='',
    [string]$Project='',
    [switch]$VerifyOnly,
    [switch]$ListPorts,
    [switch]$WinUsb,
    [switch]$ProbeUsb,
    [string]$UsbSerial='',
    [switch]$Fruit
)
$ErrorActionPreference='Stop'
if($Fruit -and -not $Project){$Project='build/fruit/td'}
if($Fruit -and -not $PSBoundParameters.ContainsKey('Model')) {
    $Model='build/fruit/weights/model.bin'
    if(-not $Project){$Project='build/fruit/td'}
}
$expectedMagic=if($Fruit){'FRU1'}else{'HFX1'}
if(($WinUsb -or $ProbeUsb) -and $Port){throw 'Choose either -WinUsb/-ProbeUsb or -Port, not both.'}
if($ProbeUsb -and ($VerifyOnly -or $ListPorts)){throw 'Run -ProbeUsb separately from -VerifyOnly/-ListPorts.'}
function Import-BoardWinUsbTransport {
    if(-not ('FtdiWinUsbTransport' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'FtdiWinUsbTransport.cs')
    }
}
if($ProbeUsb) {
    Import-BoardWinUsbTransport
    [FtdiWinUsbTransport]::Probe($UsbSerial)
    return
}
function Get-LoaderSerialPorts {
    $map='HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'
    if(-not (Test-Path -LiteralPath $map)){return}
    $key=Get-Item -LiteralPath $map
    try {
        foreach($device in $key.GetValueNames()) {
            [pscustomobject]@{
                Port=[string]$key.GetValue($device)
                Type=if($device -match 'BthModem'){'Bluetooth'}else{'Serial'}
                Device=$device
            }
        }
    } finally {$key.Dispose()}
}
if($ListPorts) {
    $ports=@(Get-LoaderSerialPorts | Sort-Object Port)
    if($ports.Count -eq 0){Write-Output 'No COM ports detected. The board may still be available with -WinUsb.'}
    else {$ports | Format-Table Port,Type,Device -AutoSize}
    Write-Output 'Use -WinUsb with the existing board 0403:6042 WinUSB driver, or select a hardware COM port. Do not use Bluetooth. FPGA UART: 921600 baud, 8N1.'
    return
}
$root=Split-Path -Parent $PSScriptRoot
$modelPath=if([IO.Path]::IsPathRooted($Model)){$Model}else{Join-Path $root $Model}
$manifestPath=if($Manifest){if([IO.Path]::IsPathRooted($Manifest)){$Manifest}else{Join-Path $root $Manifest}}else{Join-Path (Split-Path -Parent $modelPath) 'model.json'}
$modelManifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$projectConfig=$null
if($Project) {
    if(-not $Fruit){throw '-Project is supported only with -Fruit.'}
    $projectPath=if([IO.Path]::IsPathRooted($Project)){$Project}else{Join-Path $root $Project}
    $projectConfig=Get-Content -LiteralPath (Join-Path $projectPath 'candidate_config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($projectConfig.design -ne 'five_fruit_fixed_roi' -or $projectConfig.status_magic -ne 'FRU1' -or
       $projectConfig.model_sha256 -ne $modelManifest.model_sha256 -or
       $projectConfig.model_bytes -ne $modelManifest.model_bytes -or
       $projectConfig.classifier_threshold -ne $modelManifest.classifier_threshold -or
       $projectConfig.confidence_exp_sum_max -ne $modelManifest.confidence_exp_sum_max -or
       ($projectConfig.classes -join ',') -ne ($modelManifest.classes -join ',') -or
       ($projectConfig.display_labels -join ',') -ne ($modelManifest.display_labels -join ',')) {
        throw 'Selected fruit model/threshold does not match the FPGA project. No weights were sent.'
    }
}
if($modelManifest.format -ne 'HFIXCNN1' -or
   $modelManifest.weights -ne 'INT8' -or $modelManifest.activations -ne 'INT16' -or
   $modelManifest.classifier_first_op -ne 6 -or $modelManifest.last_op -ne 14 -or
   (-not $projectConfig -and $modelManifest.classifier_threshold -ne 0.65) -or
   ($Fruit -and (@($modelManifest.classes).Count -ne 5 -or
                 @($modelManifest.classes | Select-Object -Unique).Count -ne 5 -or
                 (-not $projectConfig -and ($modelManifest.classes -join ',') -ne 'apple,banana,grape,orange,pear') -or
                 (-not $projectConfig -and $modelManifest.model_bytes -ne 233472) -or
                 -not $modelManifest.requires_five_class_decoder)) -or
   (-not $Fruit -and ($modelManifest.lanes -ne 24 -or $modelManifest.model_base -ne 12582912))) {
    throw 'Incompatible model for the selected fixed-region bitstream.'
}
if((Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $modelManifest.model_sha256){throw 'Model SHA256 mismatch'}
Add-Type -TypeDefinition @'
public static class HandCnnPacket {
    public static uint Crc32(byte[] bytes, int count) {
        uint crc=0xffffffff;
        for(int j=0;j<count;j++) {
            crc^=bytes[j];
            for(int b=0;b<8;b++) crc=(crc&1)!=0 ? (crc>>1)^0xedb88320 : crc>>1;
        }
        return ~crc;
    }
    public static byte[] Make(byte[] model, int index) {
        byte[] packet=new byte[268];
        packet[0]=82;packet[1]=49;packet[2]=56;packet[3]=68;
        System.Array.Copy(System.BitConverter.GetBytes(index),0,packet,4,4);
        System.Array.Copy(model,index*256,packet,8,256);
        uint crc=0xffffffff;
        for(int j=4;j<264;j++) {
            crc^=packet[j];
            for(int b=0;b<8;b++) crc=(crc&1)!=0 ? (crc>>1)^0xedb88320 : crc>>1;
        }
        System.Array.Copy(System.BitConverter.GetBytes(~crc),0,packet,264,4);
        return packet;
    }
}
'@
$bytes=[IO.File]::ReadAllBytes($modelPath)
if($bytes.Length -ne $modelManifest.model_bytes){throw 'Model byte count mismatch'}
if($bytes.Length % 256 -ne 0){throw 'Model must be padded to 256 bytes'}
if($VerifyOnly) {
    Write-Output "FIXED_UART_MODEL_VERIFIED magic=$expectedMagic bytes=$($bytes.Length) sha256=$($modelManifest.model_sha256) classes=$(if($Fruit){($modelManifest.classes -join ',').ToUpperInvariant()}else{'PEACE,PUNCH,STOP'}) threshold=$($modelManifest.classifier_threshold)"
    return
}
$serial=$null
function Read-FixedStatus {
    [byte[]]$request=82,49,56,83
    $serial.Write($request,0,4)
    [byte[]]$response=New-Object byte[] 36
    try {for($j=0;$j -lt 36;$j++){$response[$j]=[byte]$serial.ReadByte()}}
    catch [TimeoutException] {throw 'No fixed-region status reply. Program the matching fixed-region bitstream before loading weights.'}
    if([Text.Encoding]::ASCII.GetString($response,0,4) -ne $expectedMagic -or $response[4] -ne 1) {
        throw "Expected $expectedMagic fixed-region bitstream. No weights were sent."
    }
    if([HandCnnPacket]::Crc32($response,32) -ne [BitConverter]::ToUInt32($response,32)) {throw 'Runtime status CRC mismatch'}
    return $response
}
try {
    if($WinUsb) {
        Import-BoardWinUsbTransport
        Write-Output 'HANDFIXED_WINUSB_OPEN vid=0403 pid=6042 channel=B baud=921600'
        $serial=[FtdiWinUsbTransport]::Open($UsbSerial,$Baud)
    } else {
        if(-not $Port){throw 'Use -WinUsb for the existing board WinUSB driver, -Port for a USB serial port, or -VerifyOnly to validate the model.'}
        $portInfo=@(Get-LoaderSerialPorts | Where-Object {$_.Port -eq $Port})
        if($portInfo.Type -contains 'Bluetooth') {
            throw "$Port is a Bluetooth serial port, not the FPGA USB-UART port. Use -WinUsb for the board 0403:6042 with its existing WinUSB driver, or -ListPorts to find a hardware COM port."
        }
        if([IO.Ports.SerialPort]::GetPortNames() -notcontains $Port) {
            throw "$Port is not present. Use -WinUsb with the existing board WinUSB driver, or -ListPorts to find a hardware COM port."
        }
        $serial=[IO.Ports.SerialPort]::new($Port,$Baud,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
        $serial.ReadTimeout=5000
        $serial.WriteTimeout=5000
        $serial.DtrEnable=$false
        $serial.RtsEnable=$false
        $serial.Handshake=[IO.Ports.Handshake]::None
        $serial.Open()
        $serial.DiscardInBuffer()
    }
    $before=Read-FixedStatus
    if(($before[5] -band 0xa0) -ne 0){throw 'FPGA DDR/core fault; reset the board before loading.'}
    if(($before[5] -band 1) -eq 0){throw 'FPGA DDR is not calibrated yet.'}
    if(($before[5] -band 2) -ne 0){
        if($projectConfig){throw 'A model is already loaded; runtime status cannot identify its weights. Program the selected matching bitstream before a fresh model replacement.'}
        Write-Output 'HANDFIXED_MODEL_ALREADY_READY';return
    }
    Write-Output "HANDFIXED_UART_LOADING packets=$($bytes.Length/256) bytes=$($bytes.Length)"
    for($index=0;$index -lt $bytes.Length/256;$index++) {
        $packet=[HandCnnPacket]::Make($bytes,$index)
        $accepted=$false
        $answers=@()
        for($attempt=0;$attempt -lt 4;$attempt++) {
            $serial.Write($packet,0,$packet.Length)
            try {$answer=$serial.ReadByte()}catch [TimeoutException]{$answer=-1}
            $answers+=$answer
            if($answer -eq 0x79){$accepted=$true;break}
        }
        if(-not $accepted) {
            $replyText=($answers | ForEach-Object {if($_ -lt 0){'timeout'}else{'0x{0:X2}' -f $_}}) -join ','
            if($index -eq 0 -and $answers -contains 0x1f) {
                throw "FPGA rejected packet 0 (replies=$replyText). If loading already succeeded and the board has stayed powered without reset or reprogramming, the model is still loaded; use recognition without loading again. Otherwise, a prior partial load or DDR not ready may also cause rejection. Reinitialize the FPGA before a fresh load."
            }
            throw "Packet $index failed (replies=$replyText). Check that the matching FPGA bitstream is running, DDR is ready, and UART is connected. A prior partial load requires FPGA reinitialization before restarting at packet 0."
        }
        if($index % 1024 -eq 0) {
            Write-Progress -Activity 'Load fixed-region classifier weights into FPGA DDR' -PercentComplete (100*$index/($bytes.Length/256))
            Write-Output "HANDFIXED_UART_PROGRESS accepted=$($index+1) total=$($bytes.Length/256)"
        }
    }
    Write-Progress -Activity 'Load fixed-region classifier weights into FPGA DDR' -Completed
    $after=Read-FixedStatus
    if(($after[5] -band 2) -eq 0){throw 'All packets ACKed but FPGA model_ready is false. Check the matching model CRC and bitstream.'}
    Write-Output "HANDFIXED_UART_LOAD_VERIFIED bytes=$($bytes.Length) sha256=$($modelManifest.model_sha256) model_ready=true"
} finally {if($null -ne $serial){$serial.Dispose()}}
