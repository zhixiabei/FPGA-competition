param(
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
$simulationDir=Join-Path $env:TEMP ('anlogic_resource_phase2_roms_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources=@(
    'user_source/hdl_source/fruit_merged/handcnn_normalize.v',
    'user_source/hdl_source/gamma_lut_rgb888.v',
    'sim/reference/handcnn_normalize_case_ref.v',
    'sim/tb_handcnn_normalize_equivalence.sv',
    'sim/tb_gamma_lut_rgb888.sv'
)
foreach($source in $sources) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $source) -Destination $simulationDir
}
$sourceNames=@($sources | ForEach-Object {Split-Path -Leaf $_})
$hashes=foreach($sourceName in $sourceNames) {
    [pscustomobject]@{
        File=$sourceName
        SHA256=(Get-FileHash -LiteralPath (Join-Path $simulationDir $sourceName) -Algorithm SHA256).Hash
    }
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$compile=$sourceNames -join ' '
$script=@"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $compile
vsim -t ps work.tb_handcnn_normalize_equivalence
onfinish stop
run -all
quit -sim
vsim -t ps work.tb_gamma_lut_rgb888
onfinish stop
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),
    $script,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vsim.exe') -c -do run.do -l transcript.log *> console.log
    if($LASTEXITCODE -ne 0) {throw "Resource ROM regression failed: $simulationDir/console.log"}
    $console=[IO.File]::ReadAllText((Join-Path $simulationDir 'console.log'))
    if($console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b') {
        throw "Resource ROM regression reported an error: $simulationDir/console.log"
    }
    foreach($marker in @('HANDCNN_NORMALIZE_EQUIVALENCE_PASS','GAMMA_LUT_RGB888_PASS')) {
        $matches=[regex]::Matches($console,'(?m)^\s*(?:#\s*)?'+$marker+'\b.*$')
        if($matches.Count -ne 1) {throw "Missing or duplicate $marker in $simulationDir/console.log"}
        $matches[0].Value.Trim() -replace '^#\s*',''
    }
} finally {
    Pop-Location
}
