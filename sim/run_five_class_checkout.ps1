param(
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $OutputDirectory=''
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$simulationDir=if($OutputDirectory){[IO.Path]::GetFullPath($OutputDirectory)}else{Join-Path $env:TEMP ('five_class_checkout_'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $simulationDir){throw "Output directory must be new: $simulationDir"}
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources=@(
    (Join-Path $projectRoot 'user_source\hdl_source\checkout\checkout_divider.v'),
    (Join-Path $projectRoot 'user_source\hdl_source\checkout\fruit_checkout.v'),
    (Join-Path $PSScriptRoot 'tb_five_class_checkout.sv')
)
Push-Location $simulationDir
try {
    & (Join-Path $ModelSimBin 'vlib.exe') work | Out-Null
    & (Join-Path $ModelSimBin 'vlog.exe') -sv @sources *> compile.log
    if($LASTEXITCODE -ne 0){throw 'Checkout compilation failed; see compile.log'}
    & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish exit work.tb_five_class_checkout `
        -do 'run -all; quit -code 0 -force' -l simulation.log *> console.log
    if($LASTEXITCODE -ne 0){throw 'Checkout simulation failed; see simulation.log'}
    $pass=Select-String -LiteralPath simulation.log -Pattern '^# FIVE_CLASS_CHECKOUT_PASS$'
    if(-not $pass){Get-Content -LiteralPath simulation.log -Tail 30;throw 'Checkout simulation did not pass'}
    $pass.Line.TrimStart('# ')
} finally {Pop-Location}
