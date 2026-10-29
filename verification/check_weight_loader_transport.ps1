param(
    [string]$Model=''
)
$ErrorActionPreference='Stop'
$script:checks=0
$script:simulatedSleeps=[Collections.Generic.List[int]]::new()
if(-not ('WeightLoaderMockSerial' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public sealed class WeightLoaderMockSerial {
    public int ReadTimeout { get; set; }
    public List<byte[]> Writes { get; private set; }
    public Queue<int> Replies { get; private set; }
    public int ReadCount { get; private set; }
    public WeightLoaderMockSerial(byte[] response) {
        ReadTimeout=5000;
        Writes=new List<byte[]>();
        Replies=new Queue<int>();
        foreach(byte value in response) Replies.Enqueue(value);
    }
    public void Write(object buffer, int offset, int count) {
        byte[] bytes=buffer as byte[];
        if(bytes==null) throw new InvalidOperationException("Transport expected byte[].");
        byte[] part=new byte[count];
        Array.Copy(bytes,offset,part,0,count);
        Writes.Add(part);
    }
    public int ReadByte() {
        ReadCount++;
        if(Replies.Count==0) throw new TimeoutException("Offline mock timeout.");
        int value=Replies.Dequeue();
        if(value<0) throw new TimeoutException("Offline injected timeout.");
        return value;
    }
}
'@
}

function Assert-Check {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition){throw "CHECK_FAILED: $Message"}
    $script:checks++
}
function Assert-Bytes {
    param([byte[]]$Actual,[byte[]]$Expected,[string]$Message)
    Assert-Check ($Actual.Length -eq $Expected.Length) "$Message length"
    for($byteIndex=0;$byteIndex -lt $Expected.Length;$byteIndex++) {
        if($Actual[$byteIndex] -ne $Expected[$byteIndex]) {
            throw "CHECK_FAILED: $Message byte $byteIndex actual=$($Actual[$byteIndex]) expected=$($Expected[$byteIndex])"
        }
    }
    $script:checks++
}
function Assert-Throws {
    param([scriptblock]$Action,[string]$Message)
    $thrown=$false
    try {& $Action | Out-Null} catch {$thrown=$true}
    Assert-Check $thrown $Message
}
function Add-MockReply {
    param($Mock,[byte[]]$Bytes)
    foreach($value in $Bytes){$Mock.Replies.Enqueue([int]$value)}
}

# A table-based reference is independent of the production bit-at-a-time CRC.
[uint64[]]$script:referenceTable=New-Object uint64[] 256
for($tableIndex=0;$tableIndex -lt 256;$tableIndex++) {
    [uint64]$entry=$tableIndex
    for($bitIndex=0;$bitIndex -lt 8;$bitIndex++) {
        if(($entry -band 1) -ne 0){$entry=($entry -shr 1) -bxor [uint64]3988292384}
        else {$entry=$entry -shr 1}
    }
    $script:referenceTable[$tableIndex]=$entry
}
function Get-ReferenceCrc32 {
    param([byte[]]$Bytes,[int]$Offset=0,[int]$Count=-1)
    if($Count -lt 0){$Count=$Bytes.Length-$Offset}
    [uint64]$crc=4294967295
    for($byteIndex=$Offset;$byteIndex -lt $Offset+$Count;$byteIndex++) {
        $crc=($crc -shr 8) -bxor $script:referenceTable[($crc -bxor [uint64]$Bytes[$byteIndex]) -band 255]
    }
    return [uint32]($crc -bxor [uint64]4294967295)
}
function Get-SerialRtlCrc32 {
    param([byte[]]$Bytes,[int]$Offset=0,[int]$Count=-1)
    if($Count -lt 0){$Count=$Bytes.Length-$Offset}
    [uint64]$crc=4294967295
    for($byteIndex=$Offset;$byteIndex -lt $Offset+$Count;$byteIndex++) {
        $crc=$crc -bxor [uint64]$Bytes[$byteIndex]
        for($bitIndex=0;$bitIndex -lt 8;$bitIndex++) {
            [uint64]$feedback=0
            if(($crc -band 1) -ne 0){$feedback=3988292384}
            $crc=($crc -shr 1) -bxor $feedback
        }
    }
    return [uint32]($crc -bxor [uint64]4294967295)
}
function Get-ShiftedWord32 {
    param([byte[]]$Bytes)
    [uint64]$word=4294967295
    foreach($value in $Bytes){$word=($word -shr 8) -bor ([uint64]$value -shl 24)}
    return [uint32]$word
}
function Get-ShiftedPayload128 {
    param([byte[]]$Bytes)
    [byte[]]$register=New-Object byte[] 16
    for($byteIndex=0;$byteIndex -lt 16;$byteIndex++){$register[$byteIndex]=165}
    foreach($value in $Bytes) {
        for($byteIndex=0;$byteIndex -lt 15;$byteIndex++){$register[$byteIndex]=$register[$byteIndex+1]}
        $register[15]=$value
    }
    return ,$register
}
function Set-UInt32LE {
    param([byte[]]$Bytes,[int]$Offset,[uint32]$Value)
    for($byteIndex=0;$byteIndex -lt 4;$byteIndex++) {
        $Bytes[$Offset+$byteIndex]=[byte](([uint64]$Value -shr ($byteIndex*8)) -band 255)
    }
}
function Get-UInt32LE {
    param([byte[]]$Bytes,[int]$Offset)
    [uint64]$value=0
    for($byteIndex=0;$byteIndex -lt 4;$byteIndex++) {
        $value=$value -bor ([uint64]$Bytes[$Offset+$byteIndex] -shl ($byteIndex*8))
    }
    return [uint32]$value
}
function Complete-FrameCrc {
    param([byte[]]$Frame)
    Set-UInt32LE $Frame 32 (Get-ReferenceCrc32 $Frame 0 32)
    return ,$Frame
}
function New-StatusFrame {
    [byte[]]$frame=New-Object byte[] 36
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('FRU1'),$frame,4)
    $frame[4]=1
    $frame[5]=1
    return ,(Complete-FrameCrc $frame)
}
function New-DiagnosticFrame {
    param(
        [byte]$Reason=0,
        [byte]$Flags=1,
        [uint32]$Accepted=0,
        [uint32]$Sequence=0,
        [uint32]$Calculated=305419896,
        [uint32]$Received=305419896,
        [uint32]$ModelBytes=170752,
        [uint32]$ModelCrc=3151277551
    )
    [byte[]]$frame=New-Object byte[] 36
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('R18L'),$frame,4)
    $frame[4]=1
    $frame[5]=$Reason
    $frame[6]=$Flags
    Set-UInt32LE $frame 8 $Accepted
    Set-UInt32LE $frame 12 $Sequence
    Set-UInt32LE $frame 16 $Calculated
    Set-UInt32LE $frame 20 $Received
    Set-UInt32LE $frame 24 $ModelBytes
    Set-UInt32LE $frame 28 $ModelCrc
    return ,(Complete-FrameCrc $frame)
}
function New-MockSerial {
    param([byte[]]$Response=@())
    return [WeightLoaderMockSerial]::new($Response)
}
function Join-MockWrites {
    param($Mock)
    $joined=[Collections.Generic.List[byte]]::new()
    foreach($part in $Mock.Writes){$joined.AddRange([byte[]]$part)}
    return ,$joined.ToArray()
}
# Production pacing is recorded, never slept, and no port is opened.
function Start-Sleep {
    param([int]$Milliseconds)
    $script:simulatedSleeps.Add($Milliseconds)
}

$loaderPath=Join-Path $PSScriptRoot 'load_handfixed_uart.ps1'
$tokens=$null
$parseErrors=$null
$loaderAst=[Management.Automation.Language.Parser]::ParseFile($loaderPath,[ref]$tokens,[ref]$parseErrors)
Assert-Check ($parseErrors.Count -eq 0) 'production loader parses'
$packetSource=$loaderAst.Find({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value -match 'public static class HandCnnPacket'
},$true)
Assert-Check ($null -ne $packetSource) 'production packet helper found'
if(-not ('HandCnnPacket' -as [type])){Add-Type -TypeDefinition $packetSource.Value}
foreach($functionName in @('Read-FixedStatus','Write-WeightPacket','Read-LoaderDiagnostics','Get-LoaderReasonName','Format-LoaderDiagnostics','Assert-LoaderModel')) {
    $definition=$loaderAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    },$true)
    Assert-Check ($null -ne $definition) "production function $functionName found"
    . ([scriptblock]::Create($definition.Extent.Text))
}
$packetLoop=$loaderAst.Find({
    param($node)
    $node -is [Management.Automation.Language.ForStatementAst] -and
    $node.Extent.Text -match '^for\(\$index=0;' -and
    $node.Extent.Text -match 'Write-WeightPacket'
},$true)
Assert-Check ($null -ne $packetLoop) 'production packet retry loop found'
$packetTransfer=[scriptblock]::Create($packetLoop.Extent.Text)

[byte[]]$checkVector=[Text.Encoding]::ASCII.GetBytes('123456789')
Assert-Check ((Get-ReferenceCrc32 $checkVector) -eq [uint32]3421780262) 'independent CRC standard check vector'
Assert-Check ([HandCnnPacket]::Crc32($checkVector,$checkVector.Length) -eq [uint32]3421780262) 'production CRC standard check vector'
Assert-Check ((Get-SerialRtlCrc32 $checkVector) -eq [uint32]3421780262) 'eight step serial CRC standard check vector'
Assert-Check ((Get-ReferenceCrc32 ([byte[]]@())) -eq 0) 'independent CRC empty input'
foreach($word in @(0,1,19088743,2147483648,4294967295)) {
    [byte[]]$wordBytes=New-Object byte[] 4
    Set-UInt32LE $wordBytes 0 $word
    Assert-Check ((Get-ShiftedWord32 $wordBytes) -eq $word) "fixed word shift overwrites all old bits for $word"
}

[byte[]]$fixture=New-Object byte[] 768
for($byteIndex=0;$byteIndex -lt $fixture.Length;$byteIndex++) {
    $fixture[$byteIndex]=[byte](($byteIndex*73+19) -band 255)
}
foreach($packetIndex in @(0,1,2)) {
    [byte[]]$packet=[HandCnnPacket]::Make($fixture,$packetIndex)
    Assert-Check ($packet.Length -eq 268) "packet $packetIndex length"
    Assert-Bytes ([byte[]]$packet[0..3]) ([Text.Encoding]::ASCII.GetBytes('R18D')) "packet $packetIndex header"
    Assert-Check ((Get-UInt32LE $packet 4) -eq $packetIndex) "packet $packetIndex little endian sequence"
    Assert-Bytes ([byte[]]$packet[8..263]) ([byte[]]$fixture[($packetIndex*256)..($packetIndex*256+255)]) "packet $packetIndex payload"
    Assert-Check ((Get-UInt32LE $packet 264) -eq (Get-ReferenceCrc32 $packet 4 260)) "packet $packetIndex CRC"
    Assert-Check ((Get-SerialRtlCrc32 $packet 4 260) -eq (Get-ReferenceCrc32 $packet 4 260)) "packet $packetIndex eight step serial CRC"
    Assert-Check ((Get-ShiftedWord32 ([byte[]]$packet[4..7])) -eq $packetIndex) "packet $packetIndex sequence fixed shift"
    Assert-Check ((Get-ShiftedWord32 ([byte[]]$packet[264..267])) -eq (Get-UInt32LE $packet 264)) "packet $packetIndex CRC fixed shift"
    for($beat=0;$beat -lt 16;$beat++) {
        [byte[]]$beatBytes=$packet[(8+$beat*16)..(23+$beat*16)]
        Assert-Bytes (Get-ShiftedPayload128 $beatBytes) $beatBytes "packet $packetIndex beat $beat fixed payload shift"
    }
}

$expectedMagic='FRU1'
$serial=New-MockSerial (New-StatusFrame)
$status=Read-FixedStatus
Assert-Check ($status[5] -eq 1) 'valid legacy runtime status accepted'
Assert-Bytes (Join-MockWrites $serial) ([Text.Encoding]::ASCII.GetBytes('R18S')) 'runtime status request'

[byte[]]$corrupt=New-StatusFrame
$corrupt[5]=$corrupt[5] -bxor 1
$serial=New-MockSerial $corrupt
Assert-Throws {Read-FixedStatus} 'runtime status CRC corruption rejected'
$serial=New-MockSerial
Assert-Throws {Read-FixedStatus} 'runtime status timeout rejected'

[byte[]]$packet=[HandCnnPacket]::Make($fixture,1)
$ChunkBytes=32
$ChunkDelayMs=1
$serial=New-MockSerial
$script:simulatedSleeps.Clear()
Write-WeightPacket -Packet $packet -Attempt 0
Assert-Bytes (Join-MockWrites $serial) $packet 'paced packet remains byte exact'
Assert-Check ($serial.Writes.Count -eq 9) 'default packet is split into nine writes'
Assert-Check (@($serial.Writes | Where-Object {$_.Length -gt 32}).Count -eq 0) 'default chunk bound'
Assert-Check ($script:simulatedSleeps.Count -ge 8) 'default inter-chunk gaps'
Assert-Check (@($script:simulatedSleeps | Where-Object {$_ -lt 1}).Count -eq 0) 'default gap minimum'

$serial=New-MockSerial
$script:simulatedSleeps.Clear()
Write-WeightPacket -Packet $packet -Attempt 1
Assert-Bytes (Join-MockWrites $serial) $packet 'retry packet remains byte exact'
Assert-Check (@($serial.Writes | Where-Object {$_.Length -gt 16}).Count -eq 0) 'retry chunk bound'
Assert-Check ($serial.Writes.Count -ge 17) 'retry uses smaller chunks'
Assert-Check ($script:simulatedSleeps.Count -ge 16) 'retry inter-chunk gaps'
Assert-Check (@($script:simulatedSleeps | Where-Object {$_ -lt 2}).Count -eq 0) 'retry gap minimum'

$ChunkBytes=268
$ChunkDelayMs=0
$serial=New-MockSerial
$script:simulatedSleeps.Clear()
Write-WeightPacket -Packet $packet -Attempt 0
Assert-Bytes (Join-MockWrites $serial) $packet 'explicit full packet remains byte exact'
Assert-Check ($serial.Writes.Count -eq 1) 'explicit full packet single write'
$serial=New-MockSerial
$script:simulatedSleeps.Clear()
Write-WeightPacket -Packet $packet -Attempt 3
Assert-Bytes (Join-MockWrites $serial) $packet 'explicit full packet retry remains byte exact'
Assert-Check (@($serial.Writes | Where-Object {$_.Length -gt 16}).Count -eq 0) 'retry caps explicit chunk setting'
Assert-Check ($script:simulatedSleeps.Count -ge 16) 'retry overrides disabled pacing'
Assert-Check (@($script:simulatedSleeps | Where-Object {$_ -lt 2}).Count -eq 0) 'retry overrides zero gap'

$serial=New-MockSerial
$legacyDiagnostic=Read-LoaderDiagnostics
Assert-Check ($null -eq $legacyDiagnostic) 'old firmware diagnostic timeout returns null'
Assert-Check ($serial.ReadTimeout -eq 5000) 'legacy diagnostic restores read timeout'
Assert-Bytes (Join-MockWrites $serial) ([Text.Encoding]::ASCII.GetBytes('R18L')) 'loader diagnostic request'

$serial=New-MockSerial (New-DiagnosticFrame -Reason 3 -Accepted 7 -Sequence 0 -Calculated 305419896 -Received 2271560481)
$diagnostic=Read-LoaderDiagnostics
Assert-Check ($null -ne $diagnostic) 'new firmware diagnostic response decoded'
Assert-Check ($serial.ReadTimeout -eq 5000) 'valid diagnostic restores read timeout'
Assert-Check ($diagnostic.version -eq 1 -and $diagnostic.reason -eq 3 -and $diagnostic.reason_name -eq 'not_calibrated') 'diagnostic reason decoded'
Assert-Check ($diagnostic.accepted_packets -eq 7 -and $diagnostic.packet_sequence -eq 0) 'diagnostic sequence fields decoded'
Assert-Check ($diagnostic.computed_packet_crc32 -eq 305419896 -and $diagnostic.received_packet_crc32 -eq 2271560481) 'diagnostic CRC fields decoded'
Assert-Check ($diagnostic.model_bytes -eq 170752 -and $diagnostic.model_crc32 -eq 3151277551) 'diagnostic model identity fields decoded'
Assert-Check ($diagnostic.allow_load -and -not $diagnostic.model_ready) 'diagnostic flags decoded'
Assert-LoaderModel -Diagnostics $diagnostic -ExpectedBytes 170752 -ExpectedCrc32 3151277551
Assert-Check $true 'matching diagnostic model accepted'
Assert-Throws {Assert-LoaderModel -Diagnostics $diagnostic -ExpectedBytes 233472 -ExpectedCrc32 3151277551} 'diagnostic model size mismatch rejected'
Assert-Throws {Assert-LoaderModel -Diagnostics $diagnostic -ExpectedBytes 170752 -ExpectedCrc32 3151277550} 'diagnostic model CRC mismatch rejected'
Assert-LoaderModel -Diagnostics $null -ExpectedBytes 170752 -ExpectedCrc32 3151277551
Assert-Check $true 'legacy absent diagnostic keeps model compatibility path'
Assert-Check ((Format-LoaderDiagnostics $diagnostic) -match 'not_calibrated') 'formatted diagnostic includes rejection reason'
foreach($reasonName in @('none','packet_crc','unexpected_sequence','not_calibrated','model_already_ready','sequence_out_of_range','full_model_crc','uart_framing','receive_timeout','crc_engine_overrun')) {
    $reasonIndex=@('none','packet_crc','unexpected_sequence','not_calibrated','model_already_ready','sequence_out_of_range','full_model_crc','uart_framing','receive_timeout','crc_engine_overrun').IndexOf($reasonName)
    Assert-Check ((Get-LoaderReasonName $reasonIndex) -eq $reasonName) "diagnostic reason mapping $reasonIndex"
}
[byte[]]$corrupt=New-DiagnosticFrame
$corrupt[20]=$corrupt[20] -bxor 1
$serial=New-MockSerial $corrupt
Assert-Throws {Read-LoaderDiagnostics} 'loader diagnostic CRC corruption rejected'
[byte[]]$corrupt=New-DiagnosticFrame
$corrupt[0]=88
$corrupt=Complete-FrameCrc $corrupt
$serial=New-MockSerial $corrupt
Assert-Throws {Read-LoaderDiagnostics} 'loader diagnostic wrong magic rejected'
[byte[]]$corrupt=New-DiagnosticFrame
$corrupt[4]=2
$corrupt=Complete-FrameCrc $corrupt
$serial=New-MockSerial $corrupt
Assert-Throws {Read-LoaderDiagnostics} 'loader diagnostic unknown version rejected'
$serial=New-MockSerial ([byte[]]@(82,49,56))
Assert-Throws {Read-LoaderDiagnostics} 'partial loader diagnostic timeout rejected'
Assert-Check ($serial.ReadTimeout -eq 5000) 'partial diagnostic restores read timeout'

# Execute only the production packet loop, with fake responses and one fixture
# packet. Top-level model validation and serial opening are never executed.
[byte[]]$bytes=$fixture[0..255]
[uint32]$modelCrc32=Get-ReferenceCrc32 $bytes
$ChunkBytes=32
$ChunkDelayMs=1
$diagnosticsSupported=$true
$serial=New-MockSerial ([byte[]]@(121))
& $packetTransfer | Out-Null
Assert-Check ($serial.Writes.Count -eq 9 -and $serial.ReadCount -eq 1) 'production packet loop accepts first ACK'

$serial=New-MockSerial
$serial.Replies.Enqueue(-1)
$serial.Replies.Enqueue(121)
& $packetTransfer | Out-Null
Assert-Check ($serial.Writes.Count -eq 26 -and $serial.ReadCount -eq 2) 'production packet loop retries timeout once then accepts ACK'

$serial=New-MockSerial
Add-MockReply $serial ([byte[]]@(31))
Add-MockReply $serial (New-DiagnosticFrame -Reason 1 -ModelBytes $bytes.Length -ModelCrc $modelCrc32)
Add-MockReply $serial ([byte[]]@(121))
& $packetTransfer | Out-Null
Assert-Check ($serial.Writes.Count -eq 27 -and $serial.ReadCount -eq 38) 'production packet loop queries CRC NAK then retries'
Assert-Bytes ([byte[]]$serial.Writes[9]) ([Text.Encoding]::ASCII.GetBytes('R18L')) 'production CRC NAK queries diagnostics before retry'

foreach($terminalReason in @(2,3,4,5,6,22)) {
    $serial=New-MockSerial
    Add-MockReply $serial ([byte[]]@(31))
    Add-MockReply $serial (New-DiagnosticFrame -Reason $terminalReason -ModelBytes $bytes.Length -ModelCrc $modelCrc32)
    Assert-Throws {& $packetTransfer} "production packet loop aborts terminal reason $terminalReason"
    Assert-Check ($serial.Writes.Count -eq 10 -and $serial.ReadCount -eq 37) "terminal reason $terminalReason does not retransmit"
}

$serial=New-MockSerial
for($attemptIndex=0;$attemptIndex -lt 4;$attemptIndex++) {
    Add-MockReply $serial ([byte[]]@(31))
    Add-MockReply $serial (New-DiagnosticFrame -Reason 1 -ModelBytes $bytes.Length -ModelCrc $modelCrc32)
}
Add-MockReply $serial (New-StatusFrame)
Assert-Throws {& $packetTransfer} 'production packet loop stops after four failed attempts'
Assert-Check ($serial.Writes.Count -eq 65 -and $serial.ReadCount -eq 184) 'four attempt retry bound and final status query'
Assert-Bytes ([byte[]]$serial.Writes[64]) ([Text.Encoding]::ASCII.GetBytes('R18S')) 'failed transfer requests status after retry bound'

$modelPackets=0
if($Model) {
    [byte[]]$modelBytes=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Model).Path)
    Assert-Check ($modelBytes.Length -gt 0 -and $modelBytes.Length % 256 -eq 0) 'real model is packet aligned'
    $modelPackets=$modelBytes.Length/256
    for($packetIndex=0;$packetIndex -lt $modelPackets;$packetIndex++) {
        [byte[]]$packet=[HandCnnPacket]::Make($modelBytes,$packetIndex)
        Assert-Check ((Get-UInt32LE $packet 4) -eq $packetIndex) "real packet $packetIndex sequence"
        Assert-Bytes ([byte[]]$packet[8..263]) ([byte[]]$modelBytes[($packetIndex*256)..($packetIndex*256+255)]) "real packet $packetIndex payload"
        Assert-Check ((Get-UInt32LE $packet 264) -eq (Get-ReferenceCrc32 $packet 4 260)) "real packet $packetIndex CRC"
        Assert-Check ((Get-SerialRtlCrc32 $packet 4 260) -eq (Get-ReferenceCrc32 $packet 4 260)) "real packet $packetIndex serial CRC arithmetic"
        Assert-Check ((Get-ShiftedWord32 ([byte[]]$packet[4..7])) -eq $packetIndex) "real packet $packetIndex fixed sequence shift"
        Assert-Check ((Get-ShiftedWord32 ([byte[]]$packet[264..267])) -eq (Get-UInt32LE $packet 264)) "real packet $packetIndex fixed CRC shift"
    }
    $manifestPath=Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Model).Path) 'model.json'
    if(Test-Path -LiteralPath $manifestPath) {
        $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $expectedModelCrc=[Convert]::ToUInt32(([string]$manifest.crc32 -replace '^0x',''),16)
        Assert-Check ((Get-ReferenceCrc32 $modelBytes) -eq $expectedModelCrc) 'real complete model CRC matches manifest'
        Assert-Check ((Get-SerialRtlCrc32 $modelBytes) -eq $expectedModelCrc) 'complete model serial CRC arithmetic matches manifest'
    }
}
Write-Output "WEIGHT_LOADER_TRANSPORT_CHECKS_PASSED checks=$script:checks real_packets=$modelPackets hardware_access=false hdl_execution=false"
