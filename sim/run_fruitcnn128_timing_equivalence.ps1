param(
    [string] $ReferenceRtl='',
    [string] $CandidateRtl='',
    [string] $OutputDir='',
    [ValidateSet('Portable','Vendor')][string] $MemoryModel='Portable',
    [ValidateSet('Behavioral','Vendor')][string] $MacModel='Behavioral',
    [string] $ModelSimBin='C:\altera\14.1\modelsim_ase\win32aloem',
    [string] $TdSimLib='D:\TD\sim_release\ph1p',
    [ValidateRange(30,1800)][int] $TimeoutSeconds=300
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
if(-not $ReferenceRtl) {
    $ReferenceRtl=Join-Path $root 'build/cnn_control_timing_20261031/reference/fruitcnn128_core.v'
}
if(-not $CandidateRtl) {
    $CandidateRtl=Join-Path $root 'user_source/hdl_source/fruit_merged/fruitcnn128_core.v'
}
$work=if($OutputDir) {[IO.Path]::GetFullPath($OutputDir)} else {
    Join-Path $env:TEMP ('anlogic_cnn_timing_equivalence_'+[guid]::NewGuid().ToString('N'))
}
if(Test-Path -LiteralPath $work) {
    if(@(Get-ChildItem -LiteralPath $work -Force).Count -ne 0) {
        throw "OutputDir must be new or empty: $work"
    }
} else { New-Item -ItemType Directory -Path $work | Out-Null }
foreach($tool in @('vsim.exe','vlog.exe')) {
    if(-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool) -PathType Leaf)) {
        throw "ModelSim tool is missing: $tool"
    }
}
$manifest=[ordered]@{
    Test='FRUITCNN128_TIMING_EQUIVALENCE';Status='STARTED'
    StartedAt=(Get-Date).ToString('o')
    MemoryModel=$MemoryModel;MacModel=$MacModel
    ReferenceRtl=(Resolve-Path -LiteralPath $ReferenceRtl).Path
    CandidateRtl=(Resolve-Path -LiteralPath $CandidateRtl).Path
    Variants=@()
}
$manifestPath=Join-Path $work 'validation_manifest.json'
Write-Output "Simulation output: $work"
foreach($variant in @('reference','candidate')) {
    $variantDir=Join-Path $work $variant
    New-Item -ItemType Directory -Path $variantDir | Out-Null
    $selectedRtl=if($variant -eq 'reference') {$ReferenceRtl} else {$CandidateRtl}
    Copy-Item -LiteralPath $selectedRtl -Destination (Join-Path $variantDir 'fruitcnn128_core.v')
    $goldenSource=Join-Path $root 'sim/tb_fruit_core_numeric.sv'
    $goldenText=[IO.File]::ReadAllText($goldenSource).Replace("`r`n","`n")
    $moduleNeedle='module tb_fruit_core_numeric;'
    $finishNeedle='        $finish;'
    if([regex]::Matches($goldenText,[regex]::Escape($moduleNeedle)).Count -ne 1 -or
       [regex]::Matches($goldenText,[regex]::Escape($finishNeedle)).Count -ne 1) {
        throw 'Golden numerical bench no longer has a unique module/finish barrier.'
    }
    $goldenText=$goldenText.Replace($moduleNeedle,
        $moduleNeedle+"`n    reg timing_base_complete=0, timing_extensions_complete=0;")
    $goldenText=$goldenText.Replace($finishNeedle,
        "        timing_base_complete=1;`n        wait(timing_extensions_complete);`n"+$finishNeedle)
    [IO.File]::WriteAllText((Join-Path $variantDir 'tb_fruit_core_numeric.sv'),
        $goldenText,[Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_fruitcnn128_timing_equivalence.sv') -Destination $variantDir
    $sources=@('fruitcnn128_core.v','tb_fruit_core_numeric.sv','tb_fruitcnn128_timing_equivalence.sv')
    $support=@()
    if($MacModel -eq 'Vendor') {
        $support+=Join-Path $root 'user_source/hdl_source/resnet/resnet_ph1p_dsp.v'
        foreach($name in @('ph1p_phy_dspsiou_v2.v','ph1p_phy_dspmult_v2.v','ph1p_phy_dsptadd.v')) {
            $support+=Join-Path $TdSimLib $name
        }
    } else { $support+=Join-Path $root 'sim/resnet18_dsp_reference.sv' }
    if($MemoryModel -eq 'Vendor') {
        foreach($name in @('ph1p_logic_eram.v','ph1p_logic_dram.v','ph1p_logic_dram64x8.v',
                           'ph1p_phy_mslice.v','ph1p_phy_dramhardcon.v','ph1p_phy_gsr.v')) {
            $support+=Join-Path $TdSimLib $name
        }
    } else {
        $support+=Join-Path $root 'sim/reference/fruit_core_coefficient_ram_sim.v'
        $support+=Join-Path $root 'sim/reference/ph1p_logic_dram_asym_sim.v'
        if($MacModel -eq 'Vendor') { $support+=Join-Path $TdSimLib 'ph1p_phy_gsr.v' }
    }
    foreach($source in $support) {
        Copy-Item -LiteralPath $source -Destination $variantDir
        $sources+=Split-Path -Leaf $source
    }
    $hashes=foreach($name in $sources) {
        [pscustomobject]@{File=$name;SHA256=(Get-FileHash -LiteralPath (Join-Path $variantDir $name) -Algorithm SHA256).Hash}
    }
    $hashes | Export-Csv -LiteralPath (Join-Path $variantDir 'source_sha256.csv') -NoTypeInformation
    $top='work.tb_fruitcnn128_timing_equivalence'
    if($MemoryModel -eq 'Vendor' -or $MacModel -eq 'Vendor') { $top+=' work.PH1P_PHY_GSR' }
    $sourceArgs=($sources | ForEach-Object {'{'+$_+'}'}) -join ' '
    $decodeOptions=if(Select-String -LiteralPath (Join-Path $variantDir 'fruitcnn128_core.v') `
        -Pattern '\bfunction\s+\[15:0\]\s+decoded_row_offset\b' -Quiet) {
        '+define+CNN_HAS_DECODED_ROW_OFFSET'
    } else {''}
    $script=@"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv $decodeOptions $sourceArgs
vsim -t ps $top +OUTPUT_TRACE=output_trace.txt
run -all
quit -code 0 -force
"@
    [IO.File]::WriteAllText((Join-Path $variantDir 'run.do'),$script,[Text.UTF8Encoding]::new($false))
    $consolePath=Join-Path $variantDir 'console.log'
    $stderrPath=Join-Path $variantDir 'stderr.log'
    $process=Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
        -ArgumentList @('-c','-do','run.do') -WorkingDirectory $variantDir -WindowStyle Hidden `
        -RedirectStandardOutput $consolePath -RedirectStandardError $stderrPath -PassThru
    $nativeHandle=$process.Handle
    if(-not $process.WaitForExit($TimeoutSeconds*1000)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        $manifest.Status='TIMEOUT'
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        throw "CNN $variant simulation timed out; see $consolePath"
    }
    $process.WaitForExit(); $process.Refresh()
    $console=[IO.File]::ReadAllText($consolePath)+[IO.File]::ReadAllText($stderrPath)
    $passPattern='(?m)^\s*(?:#\s*)?CNN_TIMING_EQUIVALENCE_PASS\b.*$'
    $casePattern='(?m)^\s*(?:#\s*)?CNN_TIMING_CASE_PASS\b.*$'
    $caseLines=@([regex]::Matches($console,$casePattern) | ForEach-Object {$_.Value.Trim() -replace '^#\s*',''})
    $passed=$process.ExitCode -eq 0 -and
        [regex]::Matches($console,$passPattern).Count -eq 1 -and $caseLines.Count -eq 27 -and
        $console -match 'CNN_ROW_OFFSET_EXHAUSTIVE_PASS pairs=65536\b' -and
        $console -notmatch '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b'
    $entry=@{
        Variant=$variant;Status=$(if($passed) {'PASS'} else {'FAIL'});ExitCode=$process.ExitCode
        SourceHashes=$hashes;Console=$consolePath;CaseCount=$caseLines.Count
        OutputTraceSHA256=$(if(Test-Path -LiteralPath (Join-Path $variantDir 'output_trace.txt')) {
            (Get-FileHash -LiteralPath (Join-Path $variantDir 'output_trace.txt') -Algorithm SHA256).Hash
        } else {''})
        PassMarker=([regex]::Match($console,$passPattern).Value.Trim() -replace '^#\s*','')
        CaseStatistics=$caseLines
    }
    $manifest.Variants+=@($entry)
    $manifest.Status=if($passed) {'RUNNING'} else {'FAIL'}
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if(-not $passed) { throw "CNN $variant numerical/timing regression failed; see $consolePath" }
    $entry.PassMarker
}
$referenceResult=$manifest.Variants[0]
$candidateResult=$manifest.Variants[1]
if($referenceResult.OutputTraceSHA256 -ne $candidateResult.OutputTraceSHA256) {
    $manifest.Status='FAIL'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    throw 'Reference/candidate output write traces differ; inspect per-variant output_trace.txt files.'
}
if(($referenceResult.CaseStatistics -join "`n") -cne ($candidateResult.CaseStatistics -join "`n")) {
    $manifest.Status='FAIL'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    throw 'Reference/candidate per-case cycles, MACs, DDR reads/writes, waits, or queue statistics differ.'
}
$manifest.Status='PASS'
$manifest.FinishedAt=(Get-Date).ToString('o')
$manifest.OutputsBitExact=$true
$manifest.CaseStatisticsEqual=$true
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Output "CNN_TIMING_REFERENCE_CANDIDATE_PASS golden_cases=27 lanes=24 outputs_bit_exact=1 case_statistics_equal=1 row_offset_pairs=65536 manifest=$manifestPath"
