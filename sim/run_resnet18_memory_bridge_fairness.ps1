param(
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $env:TEMP ('resnet18_bridge_fairness_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$sources=@(
    (Join-Path $root 'user_source\hdl_source\resnet18\resnet18_memory_bridge.v'),
    (Join-Path $PSScriptRoot 'tb_resnet18_memory_bridge_fairness.sv')
)
Push-Location $work
try {
    & (Join-Path $ModelSimBin 'vlib.exe') work | Out-Null
    & (Join-Path $ModelSimBin 'vlog.exe') -sv @sources *> compile.log
    if($LASTEXITCODE -ne 0){throw "Bridge compilation failed: $work/compile.log"}
    & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish exit work.tb_resnet18_memory_bridge_fairness `
        -do 'run -all; quit -code 0 -force' -l simulation.log *> console.log
    if($LASTEXITCODE -ne 0){throw "Bridge simulation failed: $work/simulation.log"}
    $pass=Select-String -LiteralPath simulation.log -Pattern '^# RESNET18_MEMORY_BRIDGE_FAIRNESS_PASS'
    if(-not $pass){Get-Content -LiteralPath simulation.log -Tail 40;throw 'Bridge fairness test did not pass'}
    $pass.Line.TrimStart('# ')
} finally {Pop-Location}
