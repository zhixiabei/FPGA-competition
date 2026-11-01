param(
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib='D:\TD\sim_release\ph1p',
    [ValidateSet('All','Core','Mirror','Bridge')][string] $Suite='All'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
$simulationDir=Join-Path $env:TEMP ('anlogic_signature_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources=@(
    'user_source/hdl_source/pen_minimal.v',
    'user_source/hdl_source/signature_control.v',
    'user_source/hdl_source/hdmi_mixer.v',
    'user_source/hdl_source/display_effects_rgb888.v',
    'user_source/hdl_source/gamma_lut_rgb888.v',
    'user_source/hdl_source/anlogic_logo_rom.v',
    'user_source/hdl_source/osd_char_lib.v',
    'user_source/hdl_source/video_out.v',
    'user_source/hdl_source/target_frame_bridge.v',
    'user_source/ip_source/w128_d512_fifo/w128_d512_fifo.v',
    'user_source/ip_source/w128_d512_fifo/soft_fifo_al_4057d6b76aa6.v',
    'sim/tb_pen_minimal.sv', 'sim/tb_signature_control.sv',
    'sim/tb_signature_mixer.sv', 'sim/tb_video_out_mirror.sv',
    'sim/tb_target_frame_bridge.sv',
    'sim/tb_target_frame_bridge_single_payload.sv'
)
$compiled=@()
foreach($relative in $sources) {
    $destination=Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $destination
    $compiled+=$destination
}
foreach($primitive in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')) {
    $destination=Join-Path $simulationDir $primitive
    Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $destination
    $compiled+=$destination
}
$dram=[regex]::Match([IO.File]::ReadAllText((Join-Path $TdSimLib 'ph1p_logic_dram.v')),
    '(?s)\A.*?\bendmodule\b')
if(!$dram.Success -or !$dram.Value.Contains('module PH1P_LOGIC_DRAM')) {throw 'Missing vendor DRAM model'}
$dramPath=Join-Path $simulationDir 'ph1p_logic_dram_functional.v'
[IO.File]::WriteAllText($dramPath,$dram.Value,[Text.UTF8Encoding]::new($false))
$compiled+=$dramPath
$cases=@()
if($Suite -in @('All','Core')) {$cases+=@('tb_signature_control','tb_pen_minimal','tb_signature_mixer')}
if($Suite -in @('All','Bridge')) {$cases+=@('tb_target_frame_bridge','tb_target_frame_bridge_single_payload')}
if($Suite -in @('All','Mirror')) {$cases+='tb_video_out_mirror'}
$tclSources=($compiled | ForEach-Object {'{'+$_.Replace('\','/')+'}'}) -join ' '
$tops=$cases -join ' '
$script=@"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $tclSources
foreach top {$tops} {
    vsim -t ps work.`$top work.PH1P_PHY_GSR
    onfinish stop
    run -all
    quit -sim
}
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),$script,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
$process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
    -ArgumentList '-c -do run.do -l transcript.log' -WorkingDirectory $simulationDir `
    -WindowStyle Hidden -RedirectStandardOutput (Join-Path $simulationDir 'console.log') `
    -RedirectStandardError (Join-Path $simulationDir 'stderr.log') -PassThru
$nativeHandle=$process.Handle
if(!$process.WaitForExit(600000)) {
    Stop-Process -Id $process.Id
    throw "Signature simulation timed out: $simulationDir"
}
$process.WaitForExit();$process.Refresh()
$console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))+
    [IO.File]::ReadAllText((Join-Path $simulationDir 'stderr.log'))
if($process.ExitCode -ne 0 -or $console -match '(?im)^\s*(?:#\s*)?(?:\*\*\s*(?:Error|Fatal)\b|(?:ERROR|FATAL):)') {
    throw "Signature simulation failed: $simulationDir\console.log"
}
foreach($top in $cases) {
    $marker=$top.Substring(3).ToUpperInvariant()+'_PASS'
    $matches=[regex]::Matches($console,"(?m)^\s*(?:#\s*)?$marker\b.*$")
    if($matches.Count -ne 1) {throw "Missing $marker : $simulationDir\console.log"}
    $matches[0].Value.Trim() -replace '^#\s*',''
}
$compiled | Get-FileHash -Algorithm SHA256 |
    Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "SIGNATURE_REGRESSION_PASS suite=$Suite cases=$($cases.Count)"
