param(
    [string] $ReferenceRtl = '',
    [string] $ReferenceRef = '9d3b6e91e1bfca11c50d03b2ed7926526ef9a66c',
    [int] $TimeoutSeconds = 600,
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $VendorRamModel = 'D:\TD\sim_release\ph1p\ph1p_logic_eram.v',
    [switch] $SkipVendor,
    [switch] $SkipPortable
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($ReferenceRtl) {
    $ReferenceRtl = (Resolve-Path -LiteralPath $ReferenceRtl).Path
    $referenceOriginal = [IO.File]::ReadAllText($ReferenceRtl)
    $referenceDescription = $ReferenceRtl
} else {
    # The committed pre-edit baseline makes this regression reproducible in
    # a clean checkout without any ignored build snapshot.
    $referencePath = 'user_source/hdl_source/isp/scharr_edge_detect_96.v'
    $resolvedRef = & git -C $projectRoot rev-parse --verify ($ReferenceRef + '^{commit}')
    if ($LASTEXITCODE -ne 0) { throw "Cannot resolve baseline commit: $ReferenceRef" }
    $referenceObject = $resolvedRef.Trim() + ':' + $referencePath
    $referenceLines = & git -C $projectRoot show --no-textconv $referenceObject
    if ($LASTEXITCODE -ne 0) { throw "Cannot read baseline source: $referenceObject" }
    $referenceOriginal = ($referenceLines -join "`n") + "`n"
    $referenceDescription = 'git:' + $referenceObject
}
if ($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
if ($SkipVendor -and $SkipPortable) { throw 'At least one RAM variant must run.' }
foreach ($tool in @('vsim.exe', 'vlog.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
if (-not $SkipVendor) {
    $VendorRamModel = (Resolve-Path -LiteralPath $VendorRamModel).Path
    $vendorGsrModel = (Resolve-Path -LiteralPath (Join-Path `
        (Split-Path -Parent $VendorRamModel) 'ph1p_phy_gsr.v')).Path
}
$simulationDir = Join-Path $env:TEMP ('anlogic_scharr_center_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @(
    (Join-Path $projectRoot 'user_source\hdl_source\isp\scharr_edge_detect_96.v'),
    (Join-Path $projectRoot 'user_source\hdl_source\isp\rgb_edge_switch_96.v'),
    (Join-Path $PSScriptRoot 'tb_scharr_center_delay_equivalence.sv'),
    (Join-Path $PSScriptRoot 'tb_scharr_morphology_equivalence.sv'),
    (Join-Path $PSScriptRoot 'tb_scharr_edge_detect_96.sv'),
    (Join-Path $PSScriptRoot 'tb_rgb_selector_local_control.sv')
)
$compiledSources = @()
$hashes = foreach ($source in $sources) {
    $destination = Join-Path $simulationDir (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $destination
    $compiledSources += $destination
    [pscustomobject]@{
        File = Split-Path -Leaf $source
        Source = $source
        SHA256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    }
}
$referenceCopy = Join-Path $simulationDir 'scharr_edge_detect_96_reference.v'
$baselineCopy = Join-Path $simulationDir 'scharr_edge_detect_96_baseline.v'
[IO.File]::WriteAllText($baselineCopy, $referenceOriginal, [Text.UTF8Encoding]::new($false))
$referenceText = $referenceOriginal
$referenceText = [regex]::Replace($referenceText,
    '\bscharr_edge_detect_96\b', 'scharr_edge_detect_96_reference')
$referenceText = [regex]::Replace($referenceText,
    '\bscharr_window_4\b', 'scharr_window_4_reference')
if ($referenceText -match '\bmodule\s+scharr_center_delay_4\b') {
    throw 'The reference must be the original full-window implementation.'
}
[IO.File]::WriteAllText($referenceCopy, $referenceText, [Text.UTF8Encoding]::new($false))
$compiledSources += $referenceCopy
$hashes += [pscustomobject]@{
    File = Split-Path -Leaf $referenceCopy
    Source = $referenceDescription
    SHA256 = (Get-FileHash -LiteralPath $baselineCopy -Algorithm SHA256).Hash
}
$hashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$tclSources = ($compiledSources | ForEach-Object { '{' + $_.Replace('\', '/') + '}' }) -join ' '
$runs = @(
    [pscustomobject]@{
        Name='portable_centers'; Library='portable'; ExtraTop=''
        Setup="vlib portable`nvlog -work portable -sv +define+SCHARR_PORTABLE_RAM $tclSources"
        Top='tb_scharr_center_delay_equivalence'; Pass='SCHARR_CENTER_EQUIVALENCE_PASS cases=6 latency=2'
    },
    [pscustomobject]@{
        Name='portable_chain'; Library='portable'; ExtraTop=''; Setup=''
        Top='tb_scharr_morphology_equivalence'; Pass='SCHARR_MORPHOLOGY_EQUIVALENCE_PASS cases=4 latency=11'
    },
    [pscustomobject]@{
        Name='portable_image'; Library='portable'; ExtraTop=''; Setup=''
        Top='tb_scharr_edge_detect_96'; Pass='SCHARR_EDGE_TEST_PASS size=64x48 gaussian=1'
    },
    [pscustomobject]@{
        Name='portable_selector'; Library='portable'; ExtraTop=''; Setup=''
        Top='tb_rgb_selector_local_control'; Pass='RGB_SELECTOR_LOCAL_CONTROL_PASS modes=16'
    }
)
if ($SkipPortable) { $runs = @() }
if (-not $SkipVendor) {
    $vendorCopy = Join-Path $simulationDir (Split-Path -Leaf $VendorRamModel)
    Copy-Item -LiteralPath $VendorRamModel -Destination $vendorCopy
    [pscustomobject]@{
        File = Split-Path -Leaf $VendorRamModel
        Source = $VendorRamModel
        SHA256 = (Get-FileHash -LiteralPath $vendorCopy -Algorithm SHA256).Hash
    } | Export-Csv -LiteralPath (Join-Path $simulationDir 'vendor_sha256.csv') -NoTypeInformation
    $vendorGsrCopy = Join-Path $simulationDir (Split-Path -Leaf $vendorGsrModel)
    Copy-Item -LiteralPath $vendorGsrModel -Destination $vendorGsrCopy
    [pscustomobject]@{
        File = Split-Path -Leaf $vendorGsrModel
        Source = $vendorGsrModel
        SHA256 = (Get-FileHash -LiteralPath $vendorGsrCopy -Algorithm SHA256).Hash
    } | Export-Csv -LiteralPath (Join-Path $simulationDir 'vendor_sha256.csv') -NoTypeInformation -Append
    $vendorTcl = '{' + $vendorCopy.Replace('\', '/') + '} {' + $vendorGsrCopy.Replace('\', '/') + '}'
    $runs += @(
        [pscustomobject]@{
            Name='vendor_centers'; Library='vendor'; ExtraTop='vendor.PH1P_PHY_GSR'
            Setup="vlib vendor`nvlog -work vendor -sv $vendorTcl $tclSources"
            Top='tb_scharr_center_delay_equivalence'; Pass='SCHARR_CENTER_EQUIVALENCE_PASS cases=6 latency=2'
        },
        [pscustomobject]@{
            Name='vendor_chain'; Library='vendor'; ExtraTop='vendor.PH1P_PHY_GSR'; Setup=''
            Top='tb_scharr_morphology_equivalence'; Pass='SCHARR_MORPHOLOGY_EQUIVALENCE_PASS cases=4 latency=11'
        },
        [pscustomobject]@{
            Name='vendor_image'; Library='vendor'; ExtraTop='vendor.PH1P_PHY_GSR'; Setup=''
            Top='tb_scharr_edge_detect_96'; Pass='SCHARR_EDGE_TEST_PASS size=64x48 gaussian=1'
        },
        [pscustomobject]@{
            Name='vendor_selector'; Library='vendor'; ExtraTop='vendor.PH1P_PHY_GSR'; Setup=''
            Top='tb_rgb_selector_local_control'; Pass='RGB_SELECTOR_LOCAL_CONTROL_PASS modes=16'
        }
    )
}
Write-Output "Simulation output: $simulationDir"
Write-Output "Reference snapshot: $referenceDescription"
foreach ($run in $runs) {
    $scriptName = $run.Name + '.do'
    $runScript = @"
onerror {quit -code 1 -force}
onbreak {resume}
$($run.Setup)
vsim -onfinish stop -L $($run.Library) -t ps $($run.Library).$($run.Top) $($run.ExtraTop)
run -all
quit -code 0 -force
"@
    [IO.File]::WriteAllText((Join-Path $simulationDir $scriptName),
        $runScript, [Text.UTF8Encoding]::new($false))
    $consolePath = Join-Path $simulationDir ($run.Name + '.console.log')
    $errorPath = Join-Path $simulationDir ($run.Name + '.stderr.log')
    $process = Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
        -ArgumentList @('-c', '-do', $scriptName, '-l', ($run.Name + '.transcript.log')) `
        -WorkingDirectory $simulationDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $consolePath -RedirectStandardError $errorPath
    # PowerShell 5 can lose ExitCode if no native handle was retained before
    # the child process exited. Hold it through the explicit wait below.
    $nativeHandle = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force
        throw "Scharr centre simulation timed out: $consolePath"
    }
    $process.WaitForExit()
    $process.Refresh()
    $console = [IO.File]::ReadAllText($consolePath)
    if ($process.ExitCode -ne 0 -or
        $console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
        $console -notmatch [regex]::Escape($run.Pass)) {
        throw "Scharr centre simulation failed (exit=$($process.ExitCode)): $consolePath"
    }
    Write-Output "Run: $($run.Name)"
    [regex]::Matches($console,
        '(?m)^\s*(?:#\s*)?(?:SCHARR_CENTER_(?:CASE|EQUIVALENCE)_PASS|SCHARR_MORPHOLOGY_(?:CASE|EQUIVALENCE)_PASS|SCHARR_EDGE_TEST_PASS|CARTOON_TEST_PASS|MORPHOLOGY_TEST_PASS)\b.*$') |
        ForEach-Object { $_.Value.Trim() -replace '^#\s*', '' }
}
