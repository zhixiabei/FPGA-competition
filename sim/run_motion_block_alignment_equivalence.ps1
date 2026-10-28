param(
    [string] $CurrentSource='',
    [int] $TimeoutSeconds=120,
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
if(-not $CurrentSource) {
    $CurrentSource=Join-Path $projectRoot 'user_source\hdl_source\isp\target_detect_switch_96.v'
}
$simulationDir=Join-Path $env:TEMP ('anlogic_motion_block_alignment_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sourceText=[IO.File]::ReadAllText($CurrentSource)
$moduleMatch=[regex]::Match($sourceText,'(?s)\bmodule motion_result_stabilizer\b.*?\bendmodule\b')
if(-not $moduleMatch.Success -or $moduleMatch.Value -notmatch '\bINPUT_BLOCK_ALIGNED\b') {
    throw "Aligned stabilizer module missing: $CurrentSource"
}
[IO.File]::WriteAllText((Join-Path $simulationDir 'stabilizer.v'),$moduleMatch.Value)
Copy-Item -LiteralPath $CurrentSource -Destination (Join-Path $simulationDir 'target_detect_switch_96.full.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_motion_block_alignment_equivalence.sv') -Destination $simulationDir
Get-ChildItem -LiteralPath $simulationDir -File | Where-Object {$_.Extension -in @('.v','.sv')} | ForEach-Object {
    [pscustomobject]@{File=$_.Name;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
} | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$script=@'
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv stabilizer.v tb_motion_block_alignment_equivalence.sv
vsim -t ps work.tb_motion_block_alignment_equivalence
run -all
quit -code 0 -force
'@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),$script)
Write-Output "Simulation output: $simulationDir"
$process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
    -ArgumentList @('-c','-do','run.do','-l','transcript.log') `
    -WorkingDirectory $simulationDir -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $simulationDir 'console.log') `
    -RedirectStandardError (Join-Path $simulationDir 'stderr.log') -PassThru
$nativeHandle=$process.Handle
if(-not $process.WaitForExit($TimeoutSeconds*1000)) {
    Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
    throw "Block-alignment equivalence timed out: $simulationDir"
}
$process.WaitForExit();$process.Refresh()
$console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))+
    [IO.File]::ReadAllText((Join-Path $simulationDir 'stderr.log'))
if($process.ExitCode -ne 0 -or
   [regex]::Matches($console,'(?m)^\s*(?:#\s*)?MOTION_BLOCK_ALIGNMENT_EQUIVALENCE_PASS\b').Count -ne 1 -or
   [regex]::Matches($console,'(?m)^\s*(?:#\s*)?MOTION_BLOCK_ALIGNMENT_CASE_PASS\b').Count -ne 3 -or
   $console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b') {
    throw "Block-alignment equivalence failed: $simulationDir/console.log"
}
[regex]::Matches($console,'(?m)^\s*(?:#\s*)?MOTION_BLOCK_ALIGNMENT_.*PASS.*$') |
    ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
