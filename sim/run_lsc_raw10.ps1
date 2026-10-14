param([string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $env:TEMP ('anlogic_lsc_raw10_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$sources=@('user_source\hdl_source\isp\lsc_raw10_4x.v','sim\tb_lsc_raw10_4x.sv')
foreach($relative in $sources) { Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $work }
& python (Join-Path $root 'verification/check_lsc_calibration.py') --sim-dir $work
if($LASTEXITCODE -ne 0) { throw 'Measured LSC calibration does not match production parameters' }
$script=@'
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv lsc_raw10_4x.v tb_lsc_raw10_4x.sv
foreach geometry {{64 17} {4 1} {4 2} {4 5} {12 7} {1280 720}} {
    lassign $geometry width height
    vsim -t ps -gW=$width -gH=$height work.tb_lsc_raw10_4x
    onfinish stop
    run -all
    quit -sim
}
quit -code 0 -force
'@
[IO.File]::WriteAllText((Join-Path $work 'run.do'),$script,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $work"
Push-Location $work
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if($LASTEXITCODE -ne 0) { throw "LSC simulation failed: $work\console.log" }
    $log=[IO.File]::ReadAllText((Join-Path $work 'console.log'))
    if($log -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
        [regex]::Matches($log,'LSC_RAW10_PASS width=').Count -ne 6) {
        throw "Incomplete or failed LSC regression: $work\console.log"
    }
    Select-String -LiteralPath console.log -Pattern 'LSC_RAW10_PASS' | ForEach-Object { $_.Line }
} finally { Pop-Location }
