param(
    [ValidateSet('Portable','Vendor','Both')]
    [string] $Mode='Both',
    [string] $ReferenceRtl='',
    [string] $CandidateRtl='',
    [switch] $HighCoordinates,
    [int] $TimeoutSeconds=600,
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib='D:\TD\sim_release\ph1p'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
if(-not $ReferenceRtl) {
    $ReferenceRtl=Join-Path $projectRoot 'build\slice_compression\baseline_project\user_source\hdl_source\isp\red_target_detect_96.v'
}
if(-not $CandidateRtl) {
    $CandidateRtl=Join-Path $projectRoot 'user_source\hdl_source\isp\red_target_detect_96.v'
}
$ReferenceRtl=(Resolve-Path -LiteralPath $ReferenceRtl).Path
$CandidateRtl=(Resolve-Path -LiteralPath $CandidateRtl).Path
if($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
foreach($tool in @('vsim.exe','vlog.exe')) {
    if(-not(Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$simulationDir=Join-Path $env:TEMP ('anlogic_red_slice_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
Copy-Item -LiteralPath $CandidateRtl -Destination (Join-Path $simulationDir 'red_target_detect_96.v')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_red_slice_compression_equivalence.sv') `
    -Destination (Join-Path $simulationDir 'tb_red_slice_compression_equivalence.sv')
$referenceText=[IO.File]::ReadAllText($ReferenceRtl)
foreach($module in @('red_target_detect_96','red_multi_run_engine',
    'color_shape_descriptor','red_multi_small_ram','red_mask_rows_4')) {
    $referenceText=[regex]::Replace($referenceText,'\b'+$module+'\b',$module+'_reference')
}
[IO.File]::WriteAllText((Join-Path $simulationDir 'red_target_detect_96_reference.v'),
    $referenceText,[Text.UTF8Encoding]::new($false))
@(
    [pscustomobject]@{File='candidate';Source=$CandidateRtl;SHA256=(Get-FileHash -LiteralPath $CandidateRtl -Algorithm SHA256).Hash}
    [pscustomobject]@{File='reference';Source=$ReferenceRtl;SHA256=(Get-FileHash -LiteralPath $ReferenceRtl -Algorithm SHA256).Hash}
    [pscustomobject]@{File='testbench';Source=(Join-Path $PSScriptRoot 'tb_red_slice_compression_equivalence.sv');SHA256=(Get-FileHash -LiteralPath (Join-Path $simulationDir 'tb_red_slice_compression_equivalence.sv') -Algorithm SHA256).Hash}
) | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "Simulation output: $simulationDir"
$variants=if($Mode -eq 'Both') {@('Portable','Vendor')} else {@($Mode)}
foreach($variant in $variants) {
    $stem=$variant.ToLowerInvariant()
    $compileOptions=if($variant -eq 'Portable') {'+define+RED_MULTI_PORTABLE_RAM'} else {''}
    $vendorSources=''
    $vendorTop=''
    $topParameters=if($HighCoordinates) {'-gW=1280 -gH=720 -gHIGH_COORD_ONLY=1'} else {''}
    if($variant -eq 'Vendor') {
        foreach($primitive in @('ph1p_logic_eram.v','ph1p_phy_gsr.v')) {
            Copy-Item -LiteralPath (Join-Path $TdSimLib $primitive) -Destination (Join-Path $simulationDir $primitive)
        }
        $vendorSources='ph1p_logic_eram.v ph1p_phy_gsr.v'
        $vendorTop='work.PH1P_PHY_GSR'
    }
    $runScript=@"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {[file exists work]} {vdel -all -lib work}
vlib work
vlog -sv $compileOptions red_target_detect_96.v red_target_detect_96_reference.v tb_red_slice_compression_equivalence.sv $vendorSources
vsim -t ps $topParameters work.tb_red_slice_compression_equivalence $vendorTop
run -all
quit -code 0 -force
"@
    [IO.File]::WriteAllText((Join-Path $simulationDir ($stem+'_run.do')),
        $runScript,[Text.UTF8Encoding]::new($false))
    $consolePath=Join-Path $simulationDir ($stem+'_console.log')
    $errorPath=Join-Path $simulationDir ($stem+'_stderr.log')
    $process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
        -ArgumentList ('-c -do '+$stem+'_run.do -l '+$stem+'_transcript.log') `
        -WorkingDirectory $simulationDir -WindowStyle Hidden `
        -RedirectStandardOutput $consolePath -RedirectStandardError $errorPath -PassThru
    if(-not $process.WaitForExit($TimeoutSeconds*1000)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        throw "$variant equivalence timed out: $consolePath"
    }
    $process.WaitForExit();$process.Refresh()
    $console=[IO.File]::ReadAllText($consolePath)+[IO.File]::ReadAllText($errorPath)
    if($process.ExitCode -ne 0 -or
       $console -match '(?im)^\s*(?:#\s*)?\*\*\s*(?:Fatal|Error)\b' -or
       $console -notmatch '(?m)^\s*(?:#\s*)?RED_SLICE_COMPRESSION_EQUIVALENCE_PASS\b') {
        throw "$variant equivalence failed: $consolePath"
    }
    [regex]::Matches($console,'(?m)^\s*(?:#\s*)?RED_SLICE_(?:SHAPE|RGB|COMPRESSION)_EQUIVALENCE_PASS\b.*$') |
        ForEach-Object {$_.Value.Trim() -replace '^#\s*',''}
}
Write-Output "RED_SLICE_COMPRESSION_REGRESSION_PASS mode=$Mode"
