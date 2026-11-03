param(
    [string] $OutputDir='',
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
if(-not $OutputDir) {
    $runId=(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $OutputDir=Join-Path $projectRoot ('build/voice_resource_fix_20261030/fruit_font_pixels_'+$runId)
}
$simulationDir=[IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources=@('hdmi_mixer.v','display_effects_rgb888.v','gamma_lut_rgb888.v',
    'anlogic_logo_rom.v','osd_char_lib.v','video_latency_osd.v')
foreach($source in $sources) {
    Copy-Item -LiteralPath (Join-Path $projectRoot ('user_source/hdl_source/'+$source)) `
        -Destination (Join-Path $simulationDir $source)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_fruit_font_pixels.sv') `
    -Destination $simulationDir
$sourceFiles=@(Get-ChildItem -LiteralPath $simulationDir -File)
$sourceFiles | Get-FileHash -Algorithm SHA256 |
    Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$compile=@($sources+'tb_fruit_font_pixels.sv') -join ' '
$runScript=@"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $compile
vsim -t ps work.tb_fruit_font_pixels
onfinish stop
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if($LASTEXITCODE -ne 0) {
        throw "Fruit font pixel simulation failed: $simulationDir/console.log"
    }
    $console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    $passes=[regex]::Matches($console,'(?m)^\s*(?:#\s*)?FRUIT_FONT_PIXELS_PASS\b.*$')
    if($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or $passes.Count -ne 1) {
        throw "Fruit font pixel verification did not pass: $simulationDir/console.log"
    }
    $passes | ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
    Add-Type -AssemblyName System.Drawing
    $previews=@(1..6 | ForEach-Object {
        [pscustomobject]@{Name="fruit_panel_class_$_";Width=320;Height=720}
    })
    $previews+=[pscustomobject]@{Name='fruit_hud_720p';Width=1280;Height=720}
    $previews+=[pscustomobject]@{Name='fruit_roi_detail';Width=488;Height=488}
    $previews+=[pscustomobject]@{Name='detection_hud_720p';Width=1280;Height=720}
    foreach($preview in $previews) {
        $width=$preview.Width
        $height=$preview.Height
        $ppmPath=Join-Path $simulationDir ($preview.Name+'.ppm')
        $pngPath=Join-Path $simulationDir ($preview.Name+'.png')
        $bytes=[IO.File]::ReadAllBytes($ppmPath)
        $header=[Text.Encoding]::ASCII.GetBytes("P6`n$width $height`n255`n")
        if($bytes.Length -ne ($header.Length+$width*$height*3)) {
            throw "Invalid PPM size: $ppmPath"
        }
        for($i=0;$i -lt $header.Length;$i++) {
            if($bytes[$i] -ne $header[$i]) {throw "Invalid PPM header: $ppmPath"}
        }
        $bitmap=[Drawing.Bitmap]::new($width,$height,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $rectangle=[Drawing.Rectangle]::new(0,0,$width,$height)
            $locked=$bitmap.LockBits($rectangle,[Drawing.Imaging.ImageLockMode]::WriteOnly,
                [Drawing.Imaging.PixelFormat]::Format24bppRgb)
            try {
                $bgr=[byte[]]::new($locked.Stride*$height)
                for($y=0;$y -lt $height;$y++) {
                    for($x=0;$x -lt $width;$x++) {
                        $src=$header.Length+($y*$width+$x)*3
                        $dst=$y*$locked.Stride+$x*3
                        $bgr[$dst]=$bytes[$src+2]
                        $bgr[$dst+1]=$bytes[$src+1]
                        $bgr[$dst+2]=$bytes[$src]
                    }
                }
                [Runtime.InteropServices.Marshal]::Copy($bgr,0,$locked.Scan0,$bgr.Length)
            } finally {
                $bitmap.UnlockBits($locked)
            }
            $bitmap.Save($pngPath,[Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $bitmap.Dispose()
        }
        Write-Output "Preview $($preview.Name): $pngPath"
    }
} finally {
    Pop-Location
}
