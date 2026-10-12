# Check the default 1280-wide LSC table as packed into the full TD gate netlist.
param([Parameter(Mandatory=$true)][string] $Netlist)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$net=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $Netlist))
$start=$net.IndexOf('// u_isp_top/u_lsc/ramread0_')
if($start -lt 0) { throw 'Synthesized LSC ROM was not found' }
$end=$net.IndexOf(');',$start)
if($end -lt 0) { throw 'Incomplete LSC ROM instance' }
$block=$net.Substring($start,$end+2-$start)
if($block -notmatch 'PH1P_PHY_ERAM_V2' -or $block -notmatch '\.DATA_WIDTH_B\("20"\)') {
    throw 'Unexpected physical LSC ROM format; update the audit before accepting'
}
function Read-InitialValue([string] $prefix,[int] $index) {
    $name=$prefix+'_'+$index.ToString('X2')
    $match=[regex]::Match($block,'\.'+$name+'\(256''h([0-9a-fA-F]+)\)')
    if(-not $match.Success) { throw "Missing ROM parameter $name" }
    return [Numerics.BigInteger]::Parse('0'+$match.Groups[1].Value,
        [Globalization.NumberStyles]::AllowHexSpecifier)
}
# Decode the actual output bit concatenations, rather than assuming that TD
# kept a byte contiguous across the 16 data + 4 parity bits of an ERAM word.
function Read-OutputMap([string] $port,[int] $width) {
    $match=[regex]::Match($block,'\.'+$port+'\(\{([^}]+)\}\)')
    if(-not $match.Success) { throw "Missing $port connection" }
    $map=@();$bit=$width-1
    foreach($token in $match.Groups[1].Value.Split(',')) {
        $coeff=[regex]::Match($token,'correct\$coefficient_d0\s+\[(\d+)(?::(\d+))?\]')
        if($coeff.Success) {
            $upper=[int]$coeff.Groups[1].Value
            $lower=if($coeff.Groups[2].Success){[int]$coeff.Groups[2].Value}else{$upper}
            for($k=$upper;$k -ge $lower;$k--) { $map+=,@($bit,$k);$bit-- }
        } elseif($token.Trim() -match '^open_n\d+$') { $bit-- }
        else { throw "Unsupported $port output token: $token" }
    }
    if($bit -ne -1) { throw "Wrong $port width" }
    return ,$map
}
$dataMap=Read-OutputMap 'dob' 16
$parityMap=Read-OutputMap 'dob_extra' 4
$coefficients=@()
for($address=0;$address -lt 160;$address++) {
    $data=Read-InitialValue 'INIT' ([int][Math]::Floor($address/16))
    $parity=Read-InitialValue 'INITP' ([int][Math]::Floor($address/64))
    $word=[int](($data -shr (16*($address%16))) -band 65535)
    $extra=[int](($parity -shr (4*($address%64))) -band 15)
    $coefficient=0
    foreach($pair in $dataMap) { $coefficient=$coefficient -bor ((($word -shr $pair[0]) -band 1) -shl $pair[1]) }
    foreach($pair in $parityMap) { $coefficient=$coefficient -bor ((($extra -shr $pair[0]) -band 1) -shl $pair[1]) }
    $distance=319-2*$address
    $expected=[int][Math]::Floor((48*$distance*$distance+50980)/101761)
    if($coefficient -ne (($expected -shl 16) -bor ($expected -shl 8))) {
        throw "LSC ROM mismatch address=$address got=$coefficient expected=$expected"
    }
    $coefficients+=$expected
}
# The netlist reuses current_x[6] as folded-address bit 6. Check that rewrite
# for every physical horizontal group, including the rightmost group.
if($block -notmatch 'correct\$rom_address \[7\].*correct\$current_x \[6\].*correct\$rom_address \[5:0\]') {
    throw 'Unexpected ROM address mapping; inspect before accepting'
}
for($x=0;$x -lt 320;$x++) {
    $mirror=[Math]::Min($x,319-$x)
    $actual=($mirror -band 191) -bor ($x -band 64)
    if($actual -ne $mirror) { throw "LSC address mapping mismatch at $x" }
}
Write-Output 'LSC_NETLIST_ROM_PASS words=160 mapped_groups=320 green_edge_q8=48 green_center_q8=0'
