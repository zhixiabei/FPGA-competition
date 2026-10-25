param(
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$simulationDir = Join-Path $env:TEMP ('anlogic_color_keep_rtl_preview_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    'user_source\hdl_source\gamma_lut_rgb888.v',
    'user_source\hdl_source\display_effects_rgb888.v',
    'sim\tb_color_keep_rtl_preview.sv'
)
$compiledSources = foreach ($relative in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $destination
    $destination
}
$hashes = foreach ($source in $compiledSources) {
    [pscustomobject]@{
        File = Split-Path -Leaf $source
        SHA256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$tclSources = ($compiledSources | ForEach-Object { '{' + $_.Replace('\', '/') + '}' }) -join ' '
$runScript = @"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv $tclSources
vsim -t ps work.tb_color_keep_rtl_preview
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $runScript,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if ($LASTEXITCODE -ne 0) { throw 'Color keep RTL preview simulation failed' }
    $console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    $pass=[regex]::Matches($console,'(?m)^\s*(?:#\s*)?COLOR_KEEP_RTL_PREVIEW_PASS\b.*$')
    if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or $pass.Count -ne 1) {
        throw 'Color keep RTL preview did not pass; see console.log'
    }
    $pass[0].Value.Trim() -replace '^#\s*',''
} finally {
    Pop-Location
}

Add-Type -AssemblyName System.Drawing
function Read-Ppm([string] $path) {
    $tokens=[regex]::Split([IO.File]::ReadAllText($path).Trim(),'\s+')
    if ($tokens[0] -ne 'P3' -or $tokens[3] -ne '255') { throw "Unexpected PPM format: $path" }
    $width=[int]$tokens[1]
    $height=[int]$tokens[2]
    if ($tokens.Length -ne 4 + $width*$height*3) { throw "Wrong PPM pixel count: $path" }
    $image=[Drawing.Bitmap]::new($width,$height)
    $index=4
    for ($y=0;$y -lt $height;$y++) {
        for ($x=0;$x -lt $width;$x++) {
            $image.SetPixel($x,$y,[Drawing.Color]::FromArgb(
                [int]$tokens[$index],[int]$tokens[$index+1],[int]$tokens[$index+2]))
            $index+=3
        }
    }
    return $image
}
$inputImage=Read-Ppm (Join-Path $simulationDir 'color_keep_input.ppm')
$outputImage=Read-Ppm (Join-Path $simulationDir 'color_keep_output.ppm')
$preview=[Drawing.Bitmap]::new(1208,548)
$graphics=[Drawing.Graphics]::FromImage($preview)
$titleFont=[Drawing.Font]::new('Arial',15,[Drawing.FontStyle]::Bold)
$labelFont=[Drawing.Font]::new('Arial',11)
$smallFont=[Drawing.Font]::new('Arial',10)
try {
    $graphics.Clear([Drawing.Color]::FromArgb(246,247,249))
    $graphics.DrawString('COLOR KEEP | RTL SYNTHETIC TEST, NOT CAMERA FOOTAGE',
        $titleFont,[Drawing.Brushes]::Black,20,15)
    $graphics.DrawString('INPUT: synthetic RGB chart',
        $labelFont,[Drawing.Brushes]::Black,20,53)
    $graphics.DrawString('MODE 05: preserve red + green, desaturate other colors',
        $labelFont,[Drawing.Brushes]::Black,614,53)
    $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::Half
    $graphics.DrawImage($inputImage,[Drawing.Rectangle]::new(20,82,576,384))
    $graphics.DrawImage($outputImage,[Drawing.Rectangle]::new(614,82,576,384))
    $graphics.DrawString('Swatches: RED / GREEN / BLUE / YELLOW / PINK / GRAY',
        $smallFont,[Drawing.Brushes]::Black,20,482)
    $graphics.DrawString('Input: generated test pixels. Output: production RTL simulation, two-clock latency.',
        $smallFont,[Drawing.Brushes]::Black,20,507)
    $outputDir=Join-Path $projectRoot 'build\verification'
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    $previewPath=Join-Path $outputDir 'color_keep_rtl_preview.png'
    $preview.Save($previewPath,[Drawing.Imaging.ImageFormat]::Png)
    Write-Output "RTL preview: $previewPath"
} finally {
    $titleFont.Dispose();$labelFont.Dispose();$smallFont.Dispose()
    $graphics.Dispose();$preview.Dispose()
    $inputImage.Dispose();$outputImage.Dispose()
}
