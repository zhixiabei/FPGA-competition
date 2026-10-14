# Check both default 1280x720 LSC tables in the full TD gate netlist.
param([Parameter(Mandatory=$true)][string] $Netlist,
      [string] $ProfileSource=(Join-Path (Split-Path -Parent $PSScriptRoot) 'user_source/hdl_source/isp/isp_top.v'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$net=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $Netlist))
$profileText=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $ProfileSource))
if($profileText.Contains('LSC_MESH_GR_Q8')) {
    & python (Join-Path $PSScriptRoot 'check_lsc_calibration.py') --netlist $Netlist --profile-source $ProfileSource
    if($LASTEXITCODE -ne 0) { throw 'Measured mesh ROM audit failed' }
    return
}
$profileValues=@{}
foreach($prefix in @('LSC_EDGE_','LSC_EDGE_Y_','LSC_MAX_')) {
    foreach($channel in @('R','GR','GB','B')) {
        $name=$prefix+$channel+'_Q8'
        $match=[regex]::Match($profileText,'parameter\s+integer\s+'+$name+'\s*=\s*(\d+)')
        if(-not $match.Success) { throw "Missing production parameter $name" }
        $profileValues[$name]=[int]$match.Groups[1].Value
    }
}
$roms=[regex]::Matches($net,'(?s)// u_isp_top/u_lsc/ramread.*?\);')
if($roms.Count -ne 2) { throw 'Expected two synthesized LSC ROMs' }
function Read-InitialValue([string] $block,[string] $prefix,[int] $index) {
    $name=$prefix+'_'+$index.ToString('X2')
    $match=[regex]::Match($block,'\.'+$name+'\(256''h([0-9a-fA-F]+)\)')
    if(-not $match.Success) { throw "Missing ROM parameter $name" }
    return [Numerics.BigInteger]::Parse('0'+$match.Groups[1].Value,
        [Globalization.NumberStyles]::AllowHexSpecifier)
}
# Decode the actual output bit concatenations in either 20-bit or 40-bit mode.
function Read-OutputMap([string] $block,[string] $coefficientName,[string] $port,[int] $width,
                        [bool] $allowAbsent=$false) {
    $match=[regex]::Match($block,'\.'+$port+'\(\{([^}]+)\}\)')
    if(-not $match.Success) {
        if($allowAbsent) { return ,@() }
        throw "Missing $port connection"
    }
    $map=@();$bit=$width-1
    foreach($token in $match.Groups[1].Value.Split(',')) {
        $coeff=[regex]::Match($token,[regex]::Escape('correct$'+$coefficientName)+'\s+\[(\d+)(?::(\d+))?\]')
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
$axes=@(
    @{Name='x'; Coefficient='coefficient_d0'; Span=320; ReusedBit=64; Prefix='LSC_EDGE_';
      Address20="{2'b00,\u_isp_top/u_lsc/correct`$rom_address [7],\u_isp_top/u_lsc/correct`$current_x [6],\u_isp_top/u_lsc/correct`$rom_address [5:0],4'b1111}";
      Address40="{1'b0,\u_isp_top/u_lsc/correct`$rom_address [7],\u_isp_top/u_lsc/correct`$current_x [6],\u_isp_top/u_lsc/correct`$rom_address [5:0],5'b11111}"},
    @{Name='y'; Coefficient='coefficient_y_d0'; Span=720; ReusedBit=16; Prefix='LSC_EDGE_Y_';
      Address20="{1'b0,\u_isp_top/u_lsc/correct`$y_rom_address [8:5],\u_isp_top/u_lsc/correct`$current_y [4],\u_isp_top/u_lsc/correct`$y_rom_address [3:0],4'b1111}";
      Address40="{\u_isp_top/u_lsc/correct`$y_rom_address [8:5],\u_isp_top/u_lsc/correct`$current_y [4],\u_isp_top/u_lsc/correct`$y_rom_address [3:0],5'b11111}"}
)
foreach($axis in $axes) {
    # Select by output signal, independent of the synthesized instance order.
    $matches=@($roms | Where-Object { $_.Value.Contains('correct$'+$axis.Coefficient+' ') })
    if($matches.Count -ne 1) { throw "Missing or ambiguous LSC $($axis.Name) ROM" }
    $block=$matches[0].Value
    $widthMatch=[regex]::Match($block,'\.DATA_WIDTH_B\("(20|40)"\)')
    if($block -notmatch 'PH1P_PHY_ERAM_V2' -or -not $widthMatch.Success) {
        throw 'Unexpected physical LSC ROM format; update the audit before accepting'
    }
    $physicalWidth=[int]$widthMatch.Groups[1].Value
    if($physicalWidth -eq 40) {
        if($block -notmatch '\.DATA_WIDTH_A\("40"\)') { throw 'Inconsistent 40-bit ROM ports' }
        $dataMap=Read-OutputMap $block $axis.Coefficient 'doa' 16
        foreach($pair in (Read-OutputMap $block $axis.Coefficient 'dob' 16)) {
            $dataMap+=,@(($pair[0]+16),$pair[1])
        }
        $parityMap=Read-OutputMap $block $axis.Coefficient 'doa_extra' 4
        foreach($pair in (Read-OutputMap $block $axis.Coefficient 'dob_extra' 4 $true)) {
            $parityMap+=,@(($pair[0]+4),$pair[1])
        }
        $dataBits=32; $parityBits=8
    } else {
        $dataMap=Read-OutputMap $block $axis.Coefficient 'dob' 16
        $parityMap=Read-OutputMap $block $axis.Coefficient 'dob_extra' 4
        $dataBits=16; $parityBits=4
    }
    $dataWords=[int](256/$dataBits); $parityWords=[int](256/$parityBits)
    $dataMask=([long]1 -shl $dataBits)-1
    $parityMask=(1 -shl $parityBits)-1
    $words=[int]($axis.Span/2)
    $denominator=($axis.Span-1)*($axis.Span-1)
    for($address=0;$address -lt $words;$address++) {
        $data=Read-InitialValue $block 'INIT' ([int][Math]::Floor($address/$dataWords))
        $parity=Read-InitialValue $block 'INITP' ([int][Math]::Floor($address/$parityWords))
        $word=[long](($data -shr ($dataBits*($address%$dataWords))) -band $dataMask)
        $extra=[int](($parity -shr ($parityBits*($address%$parityWords))) -band $parityMask)
        $coefficient=0
        foreach($pair in $dataMap) { $coefficient=$coefficient -bor ((($word -shr $pair[0]) -band 1) -shl $pair[1]) }
        foreach($pair in $parityMap) { $coefficient=$coefficient -bor ((($extra -shr $pair[0]) -band 1) -shl $pair[1]) }
        $distance=$axis.Span-1-2*$address
        $expected=0
        $shift=24
        foreach($channel in @('R','GR','GB','B')) {
            $strength=$profileValues[$axis.Prefix+$channel+'_Q8']
            $limit=$profileValues['LSC_MAX_'+$channel+'_Q8']
            $value=[int][Math]::Floor(($strength*$distance*$distance+[Math]::Floor($denominator/2))/$denominator)
            $value=[Math]::Min($limit,$value)
            $expected=$expected -bor ($value -shl $shift)
            $shift-=8
        }
        if($coefficient -ne $expected) {
            throw "LSC $($axis.Name) ROM mismatch address=$address got=$coefficient expected=$expected"
        }
    }
    # TD reuses one unfurled coordinate bit in each mirrored address. Verify
    # the actual port wiring and the identity over all groups/rows.
    foreach($port in @('addra','addrb')) {
        $connection=[regex]::Match($block,'\.'+$port+'\((\{[^}]+\})\)')
        if(-not $connection.Success -or
            ($connection.Groups[1].Value -replace '\s','') -ne ($axis['Address'+$physicalWidth] -replace '\s','')) {
            throw "Unexpected LSC $($axis.Name) $port mapping; inspect before accepting"
        }
    }
    for($position=0;$position -lt $axis.Span;$position++) {
        $mirror=[Math]::Min($position,$axis.Span-1-$position)
        $actual=($mirror -band (-bnot $axis.ReusedBit)) -bor ($position -band $axis.ReusedBit)
        if($actual -ne $mirror) { throw "LSC $($axis.Name) address mismatch at $position" }
    }
    Write-Output "LSC_NETLIST_AXIS_PASS axis=$($axis.Name) words=$words mapped_positions=$($axis.Span) eram_width=$physicalWidth"
}
Write-Output 'LSC_NETLIST_ROM_PASS x_words=160 y_words=360 production_profile_matched'
