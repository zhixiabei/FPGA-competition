param(
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$sources = @(
    'user_source\hdl_source\awb.v',
    'user_source\hdl_source\isp\rgb_edge_switch_96.v',
    'user_source\hdl_source\isp\scharr_edge_detect_96.v',
    'user_source\hdl_source\isp\data96_128\data96_128.v',
    'user_source\hdl_source\video_in.v',
    'user_source\hdl_source\video_out.v',
    'user_source\ip_source\w128_d512_fifo\w128_d512_fifo.v',
    'user_source\ip_source\w128_d512_fifo\soft_fifo_al_4057d6b76aa6.v',
    'sim\tb_video_fifo_frame_integrity.sv'
)
$simulationDir = Join-Path $env:TEMP ('anlogic_video_fifo_integrity_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources = @()
foreach ($relative in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $destination
    $compiledSources += $destination
}
foreach ($primitive in @('ph1p_logic_eram.v', 'ph1p_phy_gsr.v')) {
    $destination = Join-Path $simulationDir $primitive
    Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination $destination
    $compiledSources += $destination
}
# Use the vendor's unchanged plaintext DRAM model; the rest of the file
# contains encrypted alternate implementations unsupported by this simulator.
$primitiveText = [System.IO.File]::ReadAllText((Join-Path $TdSimLib 'ph1p_logic_dram.v'))
$primitiveModule = [regex]::Match($primitiveText, '(?s)\A.*?\bendmodule\b')
if (-not $primitiveModule.Success -or
    -not $primitiveModule.Value.Contains('module PH1P_LOGIC_DRAM')) {
    throw 'TD distributed RAM functional model was not found'
}
$primitiveSource = Join-Path $simulationDir 'ph1p_logic_dram_functional.v'
[System.IO.File]::WriteAllText($primitiveSource,
    $primitiveModule.Value + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
$compiledSources += $primitiveSource
$tclSources = ($compiledSources | ForEach-Object { '{' + $_.Replace('\', '/') + '}' }) -join ' '
$tclDir = $simulationDir.Replace('\', '/')
$runScript = @"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $tclSources
foreach phase {0.3 4.3 9.3 14.3} {
    vsim -t ps -gH=32 -gDDR_PHASE=`$phase work.tb_video_fifo_frame_integrity work.PH1P_PHY_GSR
    onfinish stop
    run -all
    quit -sim
}
vsim -t ps -gH=720 -gDDR_PHASE=9.3 work.tb_video_fifo_frame_integrity work.PH1P_PHY_GSR {+EXPORT=$tclDir}
onfinish stop
run -all
quit -sim
foreach mode {color edge} {
    vsim -t ps work.tb_video_fifo_frame_reader "+MEM=$tclDir/ddr_`${mode}.memh" "+REF=$tclDir/reference_`${mode}.memh" +FRAMES=1
    onfinish stop
    run -all
    quit -sim
}
vsim -t ps work.tb_video_fifo_frame_reader +STRESS +FRAMES=2
onfinish stop
run -all
quit -sim
quit -code 0 -force
"@
$runPath = Join-Path $simulationDir 'run.do'
[System.IO.File]::WriteAllText($runPath, $runScript, [System.Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if ($LASTEXITCODE -ne 0) {
        throw "Video FIFO simulation failed; see $simulationDir\console.log"
    }
    $console = [System.IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    # onbreak resumes after a Verilog fatal in some ModelSim versions.
    # Require every case's PASS as well as the absence of any fatal/error.
    if ($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b') {
        throw "Video FIFO simulation reported a fatal/error; see $simulationDir\console.log"
    }
    $writerPasses = [regex]::Matches($console,
        '(?m)^\s*(?:#\s*)?FIFO_FRAME_INTEGRITY_PASS H=(?<height>\d+) phase=(?<phase>[\d.]+) frames=(?<frames>\d+) bytes=(?<bytes>\d+)\s*$')
    $readerPasses = [regex]::Matches($console,
        '(?m)^\s*(?:#\s*)?FIFO_FRAME_READER_PASS frames=(?<frames>\d+) pixels=(?<pixels>\d+) side_pixels=(?<side>\d+) errors=0 underflows=0 overflows=0\s*$')
    if ($writerPasses.Count -ne 5 -or $readerPasses.Count -ne 3) {
        throw "Incomplete video FIFO coverage; see $simulationDir\console.log"
    }
    $expectedPhases = @(0.3, 4.3, 9.3, 14.3, 9.3)
    $totalWriterBytes = 0
    for ($caseIndex = 0; $caseIndex -lt $writerPasses.Count; $caseIndex++) {
        $pass = $writerPasses[$caseIndex]
        $expectedHeight = 32
        if ($caseIndex -eq 4) { $expectedHeight = 720 }
        $phase = [double]::Parse($pass.Groups['phase'].Value, [Globalization.CultureInfo]::InvariantCulture)
        $bytes = [int] $pass.Groups['bytes'].Value
        if ([int] $pass.Groups['height'].Value -ne $expectedHeight -or
            [int] $pass.Groups['frames'].Value -ne 2 -or
            $phase -ne $expectedPhases[$caseIndex] -or
            $bytes -ne $expectedHeight * 1280 * 3 * 2) {
            throw "Wrong writer coverage: $($pass.Value.Trim())"
        }
        $totalWriterBytes += $bytes
        Write-Output ($pass.Value.Trim() -replace '^#\s*', '')
    }
    $totalReaderPixels = 0
    for ($caseIndex = 0; $caseIndex -lt $readerPasses.Count; $caseIndex++) {
        $pass = $readerPasses[$caseIndex]
        $expectedFrames = 1
        if ($caseIndex -eq 2) { $expectedFrames = 2 }
        $pixels = [int] $pass.Groups['pixels'].Value
        if ([int] $pass.Groups['frames'].Value -ne $expectedFrames -or
            $pixels -ne $expectedFrames * 1280 * 720 -or
            [int] $pass.Groups['side'].Value -ne $expectedFrames * 32 * 720) {
            throw "Wrong reader coverage: $($pass.Value.Trim())"
        }
        $totalReaderPixels += $pixels
        Write-Output ($pass.Value.Trim() -replace '^#\s*', '')
    }
    foreach ($dump in @('ddr_color.memh', 'reference_color.memh', 'ddr_edge.memh', 'reference_edge.memh')) {
        if (-not (Test-Path -LiteralPath (Join-Path $simulationDir $dump) -PathType Leaf)) {
            throw "A required complete-frame dump is missing: $dump"
        }
    }
    Write-Output "VIDEO_FIFO_REGRESSION_PASS writer_bytes=$totalWriterBytes reader_pixels=$totalReaderPixels"
} finally {
    Pop-Location
}
