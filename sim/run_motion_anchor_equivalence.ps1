param(
    [string] $ReferenceSource='',
    [string] $CurrentSource='',
    [int] $TimeoutSeconds=180,
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
if(-not $ReferenceSource) {$ReferenceSource=Join-Path $root 'build/timing_resource_repair_20261027/baseline/user_source/hdl_source/isp/target_detect_switch_96.v'}
if(-not $CurrentSource) {$CurrentSource=Join-Path $root 'user_source/hdl_source/isp/target_detect_switch_96.v'}
$work=Join-Path $env:TEMP ('anlogic_motion_anchor_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
foreach($variant in @('current','reference')) {
    $source=if($variant -eq 'current') {$CurrentSource} else {$ReferenceSource}
    $text=[IO.File]::ReadAllText($source)
    $match=[regex]::Match($text,'(?s)\bmodule motion_result_stabilizer\b.*?\bendmodule\b')
    if(-not $match.Success) {throw "Stabilizer module missing: $source"}
    $rtl=$match.Value
    if($variant -eq 'reference') {$rtl=$rtl.Replace('module motion_result_stabilizer','module motion_result_stabilizer_reference')}
    [IO.File]::WriteAllText((Join-Path $work "$variant.v"),$rtl)
    Copy-Item -LiteralPath $source -Destination (Join-Path $work "$variant.full.v")
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_motion_anchor_equivalence.sv') -Destination $work
$hashes=Get-ChildItem -LiteralPath $work -File | Where-Object {$_.Name -ne 'source_sha256.csv'} | ForEach-Object {
    [pscustomobject]@{File=$_.Name;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
}
$hashes | Export-Csv -LiteralPath (Join-Path $work 'source_sha256.csv') -NoTypeInformation
$script=@'
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv current.v reference.v tb_motion_anchor_equivalence.sv
vsim -t ps work.tb_motion_anchor_equivalence
run -all
quit -code 0 -force
'@
[IO.File]::WriteAllText((Join-Path $work 'run.do'),$script)
Write-Output "Simulation output: $work"
$process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
    -ArgumentList @('-c','-do','run.do') -WorkingDirectory $work -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $work 'console.log') `
    -RedirectStandardError (Join-Path $work 'stderr.log') -PassThru
$processHandle=$process.Handle
if(-not $process.WaitForExit($TimeoutSeconds*1000)) {
    Stop-Process -Id $process.Id -Force
    throw "Motion anchor differential timed out: $work"
}
$process.WaitForExit()
$process.Refresh()
$console=[IO.File]::ReadAllText((Join-Path $work 'console.log'))+[IO.File]::ReadAllText((Join-Path $work 'stderr.log'))
if($process.ExitCode -ne 0 -or $console -notmatch 'MOTION_ANCHOR_EQUIVALENCE_PASS' -or
   $console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b') {
    throw "Motion anchor differential failed (exit=$($process.ExitCode)): $work/console.log"
}
[regex]::Matches($console,'(?m)^(?:#\s*)?MOTION_(?:ANCHOR|CENTER)_.*PASS.*$') |
    ForEach-Object {$_.Value -replace '^#\s*',''}
