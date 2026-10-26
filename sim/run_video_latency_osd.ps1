param([string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
      [string] $Python='D:\python\python.exe')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $env:TEMP ('anlogic_video_latency_osd_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$sources=@('user_source/hdl_source/video_latency_osd.v',
    'user_source/hdl_source/osd_char_lib.v','sim/tb_video_latency_osd.sv')
foreach($relative in $sources) {
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $work
}
$script=@'
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv video_latency_osd.v osd_char_lib.v tb_video_latency_osd.sv
vsim -t ps work.tb_video_latency_osd
onfinish stop
run -all
quit -sim
quit -code 0 -force
'@
[IO.File]::WriteAllText((Join-Path $work 'run.do'),$script,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $work"
Push-Location $work
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if($LASTEXITCODE -ne 0) {throw "Latency OSD simulation failed: $work\console.log"}
    $log=[IO.File]::ReadAllText((Join-Path $work 'console.log'))
    if($log -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
       $log -notmatch 'VIDEO_LATENCY_OSD_PASS') {
        throw "Incomplete or failed latency OSD regression: $work\console.log"
    }
    Select-String -LiteralPath console.log -Pattern 'VIDEO_LATENCY_OSD_PASS' |
        ForEach-Object {$_.Line}
    $previews=@('video_latency_compact')
    if(-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw "PNG preview conversion needs Python with Pillow: $Python"
    }
    & $Python -c "import sys; from PIL import Image; [Image.open(name + '.ppm').save(name + '.png') for name in sys.argv[1:]]" @previews
    if($LASTEXITCODE -ne 0) {throw "Latency OSD PNG conversion failed: $work"}
    foreach($name in $previews) {
        $png=Join-Path $work ($name+'.png')
        if(-not (Test-Path -LiteralPath $png -PathType Leaf)) {
            throw "Latency OSD preview is missing: $png"
        }
        Write-Output "Preview: $png"
    }
} finally {
    Pop-Location
}
