param(
    [string] $CoreRtl = '',
    [ValidateSet('Portable','Vendor')]
    [string] $MemoryModel = 'Portable',
    [ValidateSet('Behavioral','Vendor')]
    [string] $MacModel = 'Behavioral',
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib = 'D:\TD\sim_release\ph1p',
    [ValidateRange(30,1800)]
    [int] $TimeoutSeconds = 180,
    [switch] $RepairReturnInSnapshot,
    [switch] $ExpectBaselineFailure,
    [switch] $SkipMacOrder
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($SkipMacOrder -and -not $ExpectBaselineFailure) {
    throw 'Skipping the MAC monitor is only supported when reproducing the baseline numerical defect'
}
$root = Split-Path -Parent $PSScriptRoot
if (-not $CoreRtl) {
    $CoreRtl = Join-Path $root 'user_source/hdl_source/fruit_merged/fruitcnn128_core.v'
}
$work = Join-Path $env:TEMP ('anlogic_fruit_numeric_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$coreCopy = Join-Path $work 'fruitcnn128_core.v'
Copy-Item -LiteralPath $CoreRtl -Destination $coreCopy
if ($RepairReturnInSnapshot) {
    # A minimal functional reference for cycle comparison: repair only the
    # demonstrated cache-return omission, without changing production files.
    $text = [IO.File]::ReadAllText($coreCopy)
    $needle = "ACT_RUN:begin`n                    pipe_valid<=1;"
    $replacement = "ACT_RUN:begin`n                    state<=RUN;`n                    pipe_valid<=1;"
    $text = $text.Replace("`r`n","`n")
    if ([regex]::Matches($text,[regex]::Escape($needle)).Count -ne 1) {
        throw 'Unique original ACT_RUN block not found in reference snapshot'
    }
    [IO.File]::WriteAllText($coreCopy,$text.Replace($needle,$replacement))
}
$sources = @(
    $coreCopy,
    (Join-Path $root 'sim/tb_fruit_core_numeric.sv')
)
if ($MacModel -eq 'Vendor') {
    $sources += Join-Path $root 'user_source/hdl_source/resnet/resnet_ph1p_dsp.v'
    foreach ($name in @('ph1p_phy_dspsiou_v2.v','ph1p_phy_dspmult_v2.v','ph1p_phy_dsptadd.v')) {
        $sources += Join-Path $TdSimLib $name
    }
} else {
    $sources += Join-Path $root 'sim/resnet18_dsp_reference.sv'
}
if ($MemoryModel -eq 'Vendor') {
    foreach ($name in @('ph1p_logic_eram.v','ph1p_logic_dram.v','ph1p_logic_dram64x8.v',
                         'ph1p_phy_mslice.v','ph1p_phy_dramhardcon.v','ph1p_phy_gsr.v')) {
        $sources += Join-Path $TdSimLib $name
    }
    $top = 'work.tb_fruit_core_numeric work.PH1P_PHY_GSR'
} else {
    $sources += @(
        (Join-Path $root 'sim/reference/fruit_core_coefficient_ram_sim.v'),
        (Join-Path $root 'sim/reference/ph1p_logic_dram_asym_sim.v')
    )
    if ($MacModel -eq 'Vendor') {
        $sources += Join-Path $TdSimLib 'ph1p_phy_gsr.v'
        $top = 'work.tb_fruit_core_numeric work.PH1P_PHY_GSR'
    } else {
        $top = 'work.tb_fruit_core_numeric'
    }
}
$copied = @()
foreach ($source in $sources) {
    $target = Join-Path $work (Split-Path -Leaf $source)
    if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)) {
        Copy-Item -LiteralPath $source -Destination $target
    }
    $copied += $target
}
$copied | ForEach-Object {
    [pscustomobject]@{File=(Split-Path -Leaf $_);SHA256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}
} | Export-Csv -LiteralPath (Join-Path $work 'source_sha256.csv') -NoTypeInformation
$sourceArgs = ($copied | ForEach-Object {'{'+$_.Replace('\','/')+'}'}) -join ' '
$simulationArgs = if ($SkipMacOrder) {'+SKIP_MAC_ORDER'} else {''}
$script = @"
onerror {quit -code 1 -force}
onbreak {resume}
vlib work
vlog -sv $sourceArgs
vsim -t ps $top $simulationArgs
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $work 'run.do'),$script)
Write-Output "Simulation output: $work"
$process = Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
    -ArgumentList @('-c','-do','run.do') -WorkingDirectory $work -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $work 'console.log') `
    -RedirectStandardError (Join-Path $work 'stderr.log') -PassThru
$processHandle = $process.Handle
if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
    Stop-Process -Id $process.Id -Force
    throw "Fruit numerical regression timed out: $work"
}
$process.WaitForExit()
$process.Refresh()
$console = [IO.File]::ReadAllText((Join-Path $work 'console.log')) +
    [IO.File]::ReadAllText((Join-Path $work 'stderr.log'))
if ($ExpectBaselineFailure) {
    $expectedFailure = if ($SkipMacOrder) {'FRUIT_CORE_NUMERIC_FAIL'} else {'FRUIT_CORE_MAC_ORDER_FAIL'}
    if ($console -notmatch $expectedFailure -or $console -match 'FRUIT_CORE_NUMERIC_PASS') {
        throw "Expected baseline MAC-order defect was not reproduced: $work/console.log"
    }
    Write-Output "FRUIT_CORE_BASELINE_DEFECT_REPRODUCED $work"
} else {
    if ($process.ExitCode -ne 0 -or $console -notmatch 'FRUIT_CORE_NUMERIC_PASS' -or
        $console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b') {
        throw "Fruit numerical regression failed (exit=$($process.ExitCode)): $work/console.log"
    }
}
[regex]::Matches($console,'(?m)^(?:#\s*)?FRUIT_CORE_.*(?:PASS|FAIL).*$') |
    ForEach-Object {$_.Value -replace '^#\s*',''}
