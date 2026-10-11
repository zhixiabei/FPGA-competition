param(
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p',
    [int] $Width = 64,
    [int] $Height = 48,
    [switch] $AllowErrors,
    [switch] $LegacyRamTies,
    [switch] $CsiSource,
    [string] $DemosaicSourceRoot=''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$hdl = Join-Path $root 'user_source\hdl_source\isp\demosaic_4x_2_0'
if($DemosaicSourceRoot) { $hdl=$DemosaicSourceRoot }
$sources = @(
    'demosaic.v','raw_matrix_3x3_buffer.v','bilinear_interpolation.v',
    'mipi_to_raw_converter.v','zhenghe.v','line_buffer_demosaic.v',
    'blk_mem_gen_demosaic\blk_mem_gen_demosaic.v',
    'blk_mem_gen_demosaic\RTL\ram_c36c2ca3b3a7.v',
    'blk_mem_gen_zhenghe\blk_mem_gen_zhenghe.v',
    'blk_mem_gen_zhenghe\RTL\ram_d32970204f32.v'
) | ForEach-Object { Join-Path $hdl $_ }
$sources += Join-Path $PSScriptRoot 'tb_demosaic_quality.sv'
$sources += Join-Path $TdSimLib 'ph1p_logic_eram.v'
$sources += Join-Path $TdSimLib 'ph1p_phy_gsr.v'
if($CsiSource) {
    if($Width % 16 -ne 0) { throw 'CSI test width must be a multiple of 16' }
    if($LegacyRamTies) { throw 'CSI coverage uses the current demosaic implementation' }
    $sources += @(
        'user_source\hdl_source\isp\csi_unpacket_2lane.v',
        'user_source\hdl_source\isp\raw10_unpacket_2lane.v',
        'user_source\hdl_source\isp\uial2axis.v'
    ) | ForEach-Object { Join-Path $root $_ }
}
$work = Join-Path $env:TEMP ('anlogic_demosaic_quality_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$sourceArgs = ($sources | ForEach-Object { '{' + $_.Replace('\','/') + '}' }) -join ' '
$allow = [int] $AllowErrors.IsPresent
$csi = [int] $CsiSource.IsPresent
$defines = ''
$reference=1
if ($LegacyRamTies) {
    $defines = '+define+LEGACY_DEMOSAIC_RAM_TIES'
    $reference=0
}
$script = @"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv $defines $sourceArgs
vsim -t ps -gW=$Width -gH=$Height -gALLOW_ERRORS=$allow -gEDGE_AWARE_REFERENCE=$reference -gCSI_SOURCE=$csi work.tb_demosaic_quality work.PH1P_PHY_GSR
run -all
quit -code 0 -force
"@
# Generated simulator commands are not production RTL.
[IO.File]::WriteAllText((Join-Path $work 'run.do'),$script,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $work"
Push-Location $work
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if ($LASTEXITCODE -ne 0) { throw "Bayer simulation failed: $work\console.log" }
    $text = [IO.File]::ReadAllText((Join-Path $work 'console.log'))
    if ($text -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b') {
        throw "Bayer simulation reported an error: $work\console.log"
    }
    $result = Select-String -LiteralPath console.log -Pattern 'DEMOSAIC_QUALITY_RESULT'
    if (-not $result -or (-not $AllowErrors -and $text -notmatch 'DEMOSAIC_QUALITY_PASS')) {
        throw "Bayer simulation did not pass: $work\console.log"
    }
    if($CsiSource) {
        $csiPass=[regex]::Match($text,
            '(?m)^\s*(?:#\s*)?CSI_FRONTEND_QUALITY_PASS frames=(?<frames>\d+) raw_pixels=(?<raw>\d+) rgb_pixels=(?<rgb>\d+)\s*$')
        $expectedPixels=7*$Width*$Height
        if(-not $csiPass.Success -or
            [long] $csiPass.Groups['frames'].Value -ne 7 -or
            [long] $csiPass.Groups['raw'].Value -ne $expectedPixels -or
            [long] $csiPass.Groups['rgb'].Value -ne $expectedPixels) {
            throw "Incomplete CSI frontend coverage: $work\console.log"
        }
        Select-String -LiteralPath console.log -Pattern 'CSI_FRONTEND_QUALITY_PASS' |
            ForEach-Object { $_.Line }
    }
    $result.Line
    Select-String -LiteralPath console.log -Pattern 'GREEN_EDGE_DETAIL_PASS' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
