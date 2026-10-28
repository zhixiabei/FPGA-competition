param(
    [string] $CurrentSource=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path -Parent $PSScriptRoot
if(-not $CurrentSource) {
    $CurrentSource=Join-Path $projectRoot 'user_source/hdl_source/isp/target_detect_switch_96.v'
}
$simulationDir=Join-Path $env:TEMP ('anlogic_motion_smoothing_cpu_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
Copy-Item -LiteralPath $CurrentSource -Destination (Join-Path $simulationDir 'current.full.v')
Copy-Item -LiteralPath $PSCommandPath -Destination $simulationDir
$sourceHashes=@(Get-ChildItem -LiteralPath $simulationDir -File | ForEach-Object {
    [pscustomobject]@{File=$_.Name;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
})
$sourceHashes | Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
Write-Output "CPU arithmetic output: $simulationDir"

# Enumerate in compiled code. The independent mathematical reference uses
# positive distance and division, rather than either RTL's signed shifts.
# Actual production RTL/state/publication behavior is checked separately by
# run_motion_anchor_equivalence.ps1 against the saved original RTL.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;

public static class AnlogicMotionSmoothingProof
{
    public static string[] Run()
    {
        int[] deadbands = { 0, 1, 7, 8, 4096, Int32.MaxValue };
        long[] comparisons = new long[deadbands.Length];
        long[] holds = new long[deadbands.Length];
        long[] increasing = new long[deadbands.Length];
        long[] decreasing = new long[deadbands.Length];
        for (int previous = 0; previous < 4096; ++previous)
        {
            for (int current = 0; current < 4096; ++current)
            {
                int difference = current - previous;
                int distance = Math.Abs(difference);
                int magnitude = (distance + 3) / 4;
                int mathematical = current >= previous
                    ? previous + magnitude : previous - magnitude;

                // The legacy signed13 difference and signed14 bias/step
                // never overflow in this bounded coordinate domain.
                int legacyBias = difference + (difference < 0 ? 0 : 3);
                int legacyStep = legacyBias >> 2;
                int legacyCoordinate = (previous + legacyStep) & 4095;

                // Explicit widths model the new unsigned14 intermediate
                // assignments and the final [13:2] selection.
                int previousWeight = ((previous << 1) + previous) & 16383;
                int biasedCurrent = (current + (current >= previous ? 3 : 0)) & 16383;
                int weightedSum = previousWeight + biasedCurrent;
                if (weightedSum < 0 || weightedSum > 16383)
                    throw new InvalidOperationException("Unsigned14 weighted sum overflow");
                int weightedCoordinate = (weightedSum & 16383) >> 2;

                for (int i = 0; i < deadbands.Length; ++i)
                {
                    int deadband = deadbands[i];
                    int expected = distance <= deadband ? previous : mathematical;
                    bool rtlHold = difference >= -deadband && difference <= deadband;
                    int original = rtlHold ? previous : legacyCoordinate;
                    int optimized = rtlHold ? previous : weightedCoordinate;
                    if (expected != original || expected != optimized)
                    {
                        throw new InvalidOperationException(String.Format(
                            "Smooth mismatch deadband={0} previous={1} current={2} expected={3} original={4} optimized={5}",
                            deadband, previous, current, expected, original, optimized));
                    }
                    if (optimized < Math.Min(previous, current) ||
                        optimized > Math.Max(previous, current))
                        throw new InvalidOperationException("Smooth result escaped input interval");
                    ++comparisons[i];
                    if (distance <= deadband) ++holds[i];
                    else if (difference > 0) ++increasing[i];
                    else ++decreasing[i];
                }
            }
        }
        var results = new List<string>();
        long total = 0;
        for (int i = 0; i < deadbands.Length; ++i)
        {
            total += comparisons[i];
            results.Add(String.Format(
                "MOTION_SMOOTHING_CPU_CASE_PASS deadband={0} pairs={1} holds={2} increasing={3} decreasing={4}",
                deadbands[i], comparisons[i], holds[i], increasing[i], decreasing[i]));
        }
        results.Add(String.Format(
            "MOTION_SMOOTHING_CPU_EXHAUSTIVE_PASS previous_values=4096 current_values=4096 deadband_parameters={0} comparisons={1}",
            deadbands.Length, total));
        return results.ToArray();
    }
}
'@
$results=[AnlogicMotionSmoothingProof]::Run()
[IO.File]::WriteAllLines((Join-Path $simulationDir 'results.log'),$results)
$results
