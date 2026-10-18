param(
    [string] $VivadoBin = 'D:\Xilinx\Vivado\2021.1\bin',
    [string] $TdSimLib  = 'D:\TD\sim_release\ph1p',
    # XSim cannot execute this vendor library's encrypted implementation.
    # Use run_cnn_fixed_reference.ps1 for the ModelSim vendor-model regression.
    [switch] $UseVendorEram
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot

$eramModel = if ($UseVendorEram) {
    Join-Path $TdSimLib 'ph1p_logic_eram.v'
} else {
    Join-Path $PSScriptRoot 'reference\ph1p_logic_eram_sync_sim.v'
}
if ($UseVendorEram) {
    throw 'The PH1P encrypted model requires a supported simulator. Use run_cnn_fixed_reference.ps1.'
}

$sources = @(
    (Join-Path $PSScriptRoot 'tb_cnn_infer_32.sv'),
    (Join-Path $root 'user_source\hdl_source\cnn\cnn_infer_32.v'),
    (Join-Path $root 'user_source\hdl_source\cnn\cnn_infer_32_opt.v'),
    (Join-Path $root 'user_source\hdl_source\cnn\cnn_eram_byte_dp.v'),
    (Join-Path $root 'user_source\hdl_source\cnn\cnn_weights.v'),
    $eramModel
)
foreach ($s in $sources) {
    if (-not (Test-Path $s)) { throw "missing source: $s" }
}

$work = Join-Path $env:TEMP ('anlogic_cnn_equiv_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

# Native-command arguments must expand as an array; joining into one string
# makes xvlog treat the whole list as a single file name.
[string[]] $fileArgs = $sources | ForEach-Object { $_.Replace('\','/') }

Push-Location $work
try {
    "work dir: $work"
    "--- xvlog ---"
    & "$VivadoBin\xvlog.bat" -sv @fileArgs -log xvlog.log 2>&1 |
        Tee-Object -FilePath compile_console.log | Out-Null
    if (-not (Test-Path (Join-Path $work 'xsim.dir'))) {
        Write-Warning 'xsim.dir not created by xvlog'
    }
    if ($LASTEXITCODE -ne 0) {
        Get-Content compile_console.log -Tail 40
        throw "xvlog failed ($LASTEXITCODE)"
    }

    "--- xelab ---"
    & "$VivadoBin\xelab.bat" -timescale 1ns/1ps -debug typical work.tb_cnn_infer_32 `
        -s cnn_equiv_sim -log xelab.log 2>&1 |
        Tee-Object -FilePath elaborate_console.log | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Get-Content elaborate_console.log -Tail 40
        throw "xelab failed ($LASTEXITCODE)"
    }

    "--- xsim ---"
    & "$VivadoBin\xsim.bat" cnn_equiv_sim -runall -log xsim.log 2>&1 |
        Tee-Object -FilePath simulate_console.log | Out-Null
    $simExit = $LASTEXITCODE

    Get-Content simulate_console.log -Tail 40

    $txt = Get-Content simulate_console.log -Raw
    if ($txt -match 'CNN_INFER_EQUIV_PASS') {
        "RESULT: PASS"
        exit 0
    }
    "RESULT: FAIL"
    exit 1
}
finally {
    Pop-Location
}
