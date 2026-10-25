param(
    [string] $SimBin = 'D:\XILINX\Vivado\2021.1\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('xvlog.bat', 'xelab.bat', 'xsim.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SimBin $tool) -PathType Leaf)) {
        throw "XSim tool is missing: $tool"
    }
}
$simulationDir = Join-Path $env:TEMP ('anlogic_camera_diag_cdc_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$compiledSources = @()
foreach ($relative in @('user_source\hdl_source\camera_diag_cdc.v', 'sim\tb_camera_diag_cdc.sv')) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $destination
    $compiledSources += $destination
}
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $SimBin 'xvlog.bat') -sv @compiledSources -log xvlog.log *> compile_console.log
    if ($LASTEXITCODE -ne 0) { throw 'CDC compile failed; see compile_console.log' }
    foreach ($resetData in @(0, 128, 3968)) {
        $snapshot = "camera_diag_cdc_$resetData"
        $genericArg = '"RESET_DATA=' + $resetData + '"'
        & (Join-Path $SimBin 'xelab.bat') -timescale 1ns/1ps -debug typical `
            -generic_top $genericArg work.tb_camera_diag_cdc -s $snapshot `
            -log "xelab_$resetData.log" *> "elaborate_$resetData.log"
        if ($LASTEXITCODE -ne 0) { throw "CDC elaboration failed; see elaborate_$resetData.log" }
        & (Join-Path $SimBin 'xsim.bat') $snapshot -runall `
            -log "xsim_$resetData.log" *> "simulate_$resetData.log"
        if ($LASTEXITCODE -ne 0) { throw "CDC simulation failed; see simulate_$resetData.log" }
        $console = [IO.File]::ReadAllText((Join-Path $simulationDir "simulate_$resetData.log"))
        if ($console -match '(?im)^\s*(?:Fatal|Error|ERROR|FATAL)\b' -or
            [regex]::Matches($console, '(?m)^PASS tb_camera_diag_cdc:').Count -ne 1) {
            throw "CDC regression did not pass; see simulate_$resetData.log"
        }
        Select-String -LiteralPath "simulate_$resetData.log" -Pattern '^PASS tb_camera_diag_cdc:' |
            ForEach-Object { $_.Line }
    }
} finally {
    Pop-Location
}
