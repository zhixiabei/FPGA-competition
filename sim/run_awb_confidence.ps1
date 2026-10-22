param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p',
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
    $runName = 'awb_confidence_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' +
        [guid]::NewGuid().ToString('N').Substring(0,8)
    $OutputDirectory = Join-Path $projectRoot ('build\backlight_awb\verification\' + $runName)
}
$simulationDir = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $simulationDir | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'user_source\hdl_source\awb.v') `
    -Destination (Join-Path $simulationDir 'awb.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_awb_confidence.sv') `
    -Destination (Join-Path $simulationDir 'tb_awb_confidence.sv')
$primitiveText = [IO.File]::ReadAllText((Join-Path $TdSimLib 'ph1p_logic_dram.v'))
$primitiveModule = [regex]::Match($primitiveText,'(?s)\A.*?\bendmodule\b')
if (-not $primitiveModule.Success -or
    -not $primitiveModule.Value.Contains('module PH1P_LOGIC_DRAM')) {
    throw 'TD functional distributed RAM model was not found'
}
[IO.File]::WriteAllText((Join-Path $simulationDir 'ph1p_logic_dram.v'),
    $primitiveModule.Value,[Text.UTF8Encoding]::new($false))
$sourceNames = @('awb.v','tb_awb_confidence.sv','ph1p_logic_dram.v')
$hashes = foreach ($name in $sourceNames) {
    [pscustomobject]@{
        File = $name
        SHA256 = (Get-FileHash -LiteralPath (Join-Path $simulationDir $name) -Algorithm SHA256).Hash
    }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @sourceNames -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $simulationDir\compile_console.log" }
    & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
        work.tb_awb_confidence -s awb_confidence -log xelab.log *> elaborate_console.log
    if ($LASTEXITCODE -ne 0) { throw "Elaboration failed: $simulationDir\elaborate_console.log" }
    & (Join-Path $SimBin 'xsim.bat') awb_confidence -runall -log xsim.log *> simulate_console.log
    if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $simulationDir\simulate_console.log" }
    $console = [IO.File]::ReadAllText((Join-Path $simulationDir 'simulate_console.log'))
    if ($console -match '(?im)^\s*(?:FATAL_ERROR|Fatal|Error|ERROR|FATAL)\b' -or
        [regex]::Matches($console,'(?m)^AWB_CONFIDENCE_PASS\b').Count -ne 1) {
        throw "AWB confidence did not pass: $simulationDir\simulate_console.log"
    }
    Select-String -LiteralPath simulate_console.log -Pattern '^AWB_CONFIDENCE_PASS' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
