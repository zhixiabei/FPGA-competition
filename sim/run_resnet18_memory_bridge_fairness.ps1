param(
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $env:TEMP ('resnet18_bridge_fairness_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$sources=@(
    (Join-Path $root 'user_source\hdl_source\resnet18\resnet18_memory_bridge.v'),
    (Join-Path $PSScriptRoot 'tb_resnet18_memory_bridge_fairness.sv'),
    (Join-Path $PSScriptRoot 'tb_resnet18_memory_bridge_backpressure.sv'),
    (Join-Path $PSScriptRoot 'tb_resnet18_owner_prefetch.sv')
)
Push-Location $work
try {
    & (Join-Path $ModelSimBin 'vlib.exe') work | Out-Null
    & (Join-Path $ModelSimBin 'vlog.exe') -sv @sources *> compile.log
    if($LASTEXITCODE -ne 0){throw "Bridge compilation failed: $work/compile.log"}
    foreach($case in @('memory_bridge_fairness','memory_bridge_backpressure','owner_prefetch')) {
        & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish exit "work.tb_resnet18_$case" `
            -do 'run -all; quit -code 0 -force' -l "$case.log" *> "$case-console.log"
        if($LASTEXITCODE -ne 0){throw "Bridge simulation failed: $work/$case.log"}
        $pass=Select-String -LiteralPath "$case.log" -Pattern "^# RESNET18_$($case.ToUpper())_PASS"
        if(-not $pass){Get-Content -LiteralPath "$case.log" -Tail 40;throw "Bridge $case test did not pass"}
        $pass.Line.TrimStart('# ')
    }
} finally {Pop-Location}
