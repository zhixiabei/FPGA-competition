param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('xvlog.bat','xelab.bat','xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "Missing XSim tool: $tool"
    }
}
if (-not $OutputDirectory) {
    $runName = 'iq_diagnostics_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' +
        [guid]::NewGuid().ToString('N').Substring(0,8)
    $OutputDirectory = Join-Path $projectRoot ('build\backlight_awb\verification\' + $runName)
}
$simulationDir = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    'user_source\hdl_source\isp\iq_diagnostic_stats.v',
    'user_source\hdl_source\isp\ae_frame_stats_raw10_4x.v',
    'user_source\hdl_source\isp\lsc_raw10_4x.v',
    'sim\tb_iq_diagnostic_stats.sv'
)
$sourceNames = @()
$hashes = foreach ($relative in $sources) {
    $source = Join-Path $projectRoot $relative
    $name = Split-Path -Leaf $source
    $snapshot = Join-Path $simulationDir $name
    Copy-Item -LiteralPath $source -Destination $snapshot
    $sourceNames += $name
    [pscustomobject]@{
        File = $relative.Replace('\','/')
        SHA256 = (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
    }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$tests = @(
    @{Name='iq_bggr_black64';Width=64;Height=16;Bayer=0;Black=64;Mesh=0;Lsc=1;Full=1},
    @{Name='iq_rggb_black0';Width=64;Height=16;Bayer=1;Black=0;Mesh=0;Lsc=1;Full=1},
    @{Name='iq_gbrg_black64';Width=64;Height=16;Bayer=2;Black=64;Mesh=0;Lsc=1;Full=1},
    @{Name='iq_grbg_black0';Width=64;Height=16;Bayer=3;Black=0;Mesh=0;Lsc=1;Full=1},
    @{Name='iq_bypass';Width=64;Height=16;Bayer=0;Black=64;Mesh=0;Lsc=0;Full=1},
    @{Name='iq_720p_legacy';Width=1280;Height=720;Bayer=0;Black=64;Mesh=0;Lsc=1;Full=0},
    @{Name='iq_720p_mesh';Width=1280;Height=720;Bayer=0;Black=64;Mesh=1;Lsc=1;Full=0}
)
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @sourceNames -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $simulationDir\compile_console.log" }
    foreach ($test in $tests) {
        $generics = @(
            '-generic_top', ('"WIDTH=' + $test.Width + '"'),
            '-generic_top', ('"HEIGHT=' + $test.Height + '"'),
            '-generic_top', ('"BAYER=' + $test.Bayer + '"'),
            '-generic_top', ('"BLACK=' + $test.Black + '"'),
            '-generic_top', ('"MESH=' + $test.Mesh + '"'),
            '-generic_top', ('"LSC_ENABLE=' + $test.Lsc + '"'),
            '-generic_top', ('"FULL_SUITE=' + $test.Full + '"')
        )
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            work.tb_iq_diagnostic_stats @generics -s $test.Name `
            -log ($test.Name+'_xelab.log') *> ($test.Name+'_elaborate_console.log')
        if ($LASTEXITCODE -ne 0) { throw "Elaboration failed: $simulationDir\$($test.Name)_elaborate_console.log" }
        & (Join-Path $SimBin 'xsim.bat') $test.Name -runall `
            -log ($test.Name+'_xsim.log') *> ($test.Name+'_simulate_console.log')
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $simulationDir\$($test.Name)_simulate_console.log" }
        $console = [IO.File]::ReadAllText((Join-Path $simulationDir ($test.Name+'_simulate_console.log')))
        if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
            [regex]::Matches($console,'(?m)^IQ_DIAGNOSTIC_STATS_PASS\b').Count -ne 1) {
            throw "Diagnostics did not pass: $simulationDir\$($test.Name)_simulate_console.log"
        }
        Select-String -LiteralPath ($test.Name+'_simulate_console.log') `
            -Pattern '^IQ_DIAGNOSTIC_STATS_PASS' | ForEach-Object { $_.Line }
    }
} finally {
    Pop-Location
}
