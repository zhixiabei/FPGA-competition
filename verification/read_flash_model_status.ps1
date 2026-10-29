param([string]$Port='COM3',[ValidateSet('R18F','R18S')][string]$Command='R18F')
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
public static class FlashStatusCrc {
 public static uint Compute(byte[] data,int count) {
  uint c=0xffffffff;for(int i=0;i<count;i++) { c^=data[i];for(int j=0;j<8;j++)c=(c>>1)^((c&1)!=0?0xedb88320u:0u); }return ~c;
 }
}
'@
$serial=[IO.Ports.SerialPort]::new($Port,921600,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.ReadTimeout=2000;$serial.WriteTimeout=2000
try {
    $serial.Open();$serial.DiscardInBuffer()
    $serial.Write($Command)
    $data=[byte[]]::new(36)
    for($i=0;$i -lt 36;$i++){$data[$i]=[byte]$serial.ReadByte()}
    if([FlashStatusCrc]::Compute($data,32) -ne [BitConverter]::ToUInt32($data,32)){throw 'Status CRC mismatch'}
    $magic=[Text.Encoding]::ASCII.GetString($data,0,4)
    $result=[ordered]@{magic=$magic;version=$data[4]}
    if($magic -eq 'FPG1') {
        $result.state=$data[5];$result.error=$data[6];$result.finished=[bool]$data[7]
        $result.jedec_id='0x{0:X6}' -f [BitConverter]::ToUInt32($data,8)
        $result.offset=[BitConverter]::ToUInt32($data,12)
        $result.model_bytes=[BitConverter]::ToUInt32($data,16)
        $result.model_crc32='0x{0:X8}' -f [BitConverter]::ToUInt32($data,20)
        $result.flash_address='0x{0:X6}' -f [BitConverter]::ToUInt32($data,24)
    } elseif($magic -eq 'FBT1') {
        $result.state=$data[5];$result.error=$data[6];$result.model_ready=[bool]$data[7]
        $result.offset=[BitConverter]::ToUInt32($data,8)
        $result.flash_crc32='0x{0:X8}' -f [BitConverter]::ToUInt32($data,12)
        $result.ddr_crc32='0x{0:X8}' -f [BitConverter]::ToUInt32($data,16)
        $result.model_bytes=[BitConverter]::ToUInt32($data,20)
        $result.model_crc32='0x{0:X8}' -f [BitConverter]::ToUInt32($data,24)
        $result.flash_address='0x{0:X6}' -f [BitConverter]::ToUInt32($data,28)
    } elseif($magic -eq 'FRU1') {
        $result.flags='0x{0:X2}' -f $data[5]
        $result.model_ready=($data[5] -band 2) -ne 0
        $result.result_count=[BitConverter]::ToUInt16($data,8)
        $result.fruit_class=$data[6] -band 7
    } else {throw "Unexpected status: $magic"}
    [pscustomobject]$result | ConvertTo-Json
} finally {$serial.Dispose()}
