param(
    [string] $ReferenceRtl='',
    [string] $CurrentRtl='',
    [ValidateRange(30,1800)]
    [int] $TimeoutSeconds=180,
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
if(-not $ReferenceRtl) {
    $ReferenceRtl=Join-Path $root 'build/shape_display_compression/baseline_20261027/user_source/hdl_source/isp/red_target_detect_96.v'
}
if(-not $CurrentRtl) {
    $CurrentRtl=Join-Path $root 'user_source/hdl_source/isp/red_target_detect_96.v'
}
$work=Join-Path $env:TEMP ('anlogic_shape_descriptor_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
foreach($variant in @('current','reference')) {
    $source=if($variant -eq 'reference') {$ReferenceRtl} else {$CurrentRtl}
    $text=[IO.File]::ReadAllText($source)
    $match=[regex]::Match($text,'(?s)\bmodule color_shape_descriptor\b.*?\bendmodule\b')
    if(-not $match.Success) {throw "Descriptor not found: $source"}
    $rtl=$match.Value
    if($variant -eq 'reference') {
        $rtl=$rtl.Replace('module color_shape_descriptor','module color_shape_descriptor_reference')
    }
    [IO.File]::WriteAllText((Join-Path $work "$variant.v"),$rtl)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_shape_descriptor_equivalence.sv') -Destination $work
@('current.v','reference.v','tb_shape_descriptor_equivalence.sv') | ForEach-Object {
    [pscustomobject]@{
        File=$_
        SHA256=(Get-FileHash -LiteralPath (Join-Path $work $_) -Algorithm SHA256).Hash
    }
} | Export-Csv -LiteralPath (Join-Path $work 'source_sha256.csv') -NoTypeInformation
$script=@'
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv current.v reference.v tb_shape_descriptor_equivalence.sv
vsim -t ps work.tb_shape_descriptor_equivalence
run -all
quit -code 0 -force
'@
[IO.File]::WriteAllText((Join-Path $work 'run.do'),$script)
Write-Output "Simulation output: $work"
$process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
    -ArgumentList @('-c','-do','run.do') -WorkingDirectory $work -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $work 'console.log') `
    -RedirectStandardError (Join-Path $work 'stderr.log') -PassThru
# Retain the native handle before the process exits (Windows PowerShell 5).
$processHandle=$process.Handle
if(-not $process.WaitForExit($TimeoutSeconds*1000)) {
    Stop-Process -Id $process.Id -Force
    throw "Shape differential timed out: $work"
}
$process.WaitForExit()
$process.Refresh()
$console=[IO.File]::ReadAllText((Join-Path $work 'console.log'))+
    [IO.File]::ReadAllText((Join-Path $work 'stderr.log'))
if($process.ExitCode -ne 0 -or $console -notmatch 'SHAPE_DESCRIPTOR_EQUIVALENCE_PASS' -or
   $console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b') {
    throw "Shape differential failed (exit=$($process.ExitCode)): $work/console.log"
}
[regex]::Matches($console,'(?m)^(?:#\s*)?SHAPE_DESCRIPTOR_.*PASS.*$') |
    ForEach-Object {$_.Value -replace '^#\s*',''}
