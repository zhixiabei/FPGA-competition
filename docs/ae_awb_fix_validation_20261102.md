# AE/AWB Hold Repair - 2026-11-02

Historical record of the first, rejected attempt. Later work retains the
histogram and uses the revised modest-growth budget; see
`ae_awb_repair_validation_20261102.md`. References below to the restored
workspace and unavailable driver options describe the end of that earlier
attempt, not the current workspace.

Status: NOT ADOPTED. Functional regression passed, but the required physical
acceptance was not established. Both routing attempts were stopped early;
neither has final routed timing or DRC signoff. Candidate production changes
and their dependent tests/build changes were reverted. The original release
and the user's pre-existing edits are preserved.

All synthesis inputs in the restored workspace match the original release's
source_sha256.csv. The original programming bitstream SHA256 remains:
BD86F2A74F522142AF5EC5AAD636B6B901B59BFFB97DE4A38227D506928D3C97.

The candidate files are archived under build/ae_awb_fix/candidate_source;
tracked changes are also in build/ae_awb_fix/candidate_tracked.patch. The
comparison helper and this report are the only new maintained workspace files.

## Candidate Scope (Reverted, Archived)

- AE retains its six-frame mean, three-frame settling interval, target 96..120,
  exposure 4..1991, and gain 16..176. No exposure arithmetic or I2C table changes.
- AE holds AWB until an entire accepted statistics window needs no new sensor
  setting. At an exposure/gain limit, an unchanged setting also releases AWB.
- AWB consumes hold even when CONFIDENCE_ENABLE=0. Hold cancels queued and
  in-progress ratios and invalidates the affected frame, including blanking.
  A subsequent complete clean frame can produce a new ratio.
- The RGB correction arithmetic, eight AWB DSPs, early SOF marker and 54-clock
  data/valid/last delay are unchanged. Active gains remain fixed during hold.
- Unused production AE percentiles are disabled. IQ_DIAGNOSTIC_ENABLE=1 still
  enables the histogram. AE HIGHLIGHT_ENABLE remains zero.
- The existing two-stage AE-to-ISP hold synchronizer is now functional. Only
  source-to-first-stage is false-pathed; the second stage and AWB paths remain
  timed. Clock periods and mailbox max-delay constraints are unchanged.

## Deferred Work

Two-frame fast AE, full AWB confidence filtering and Gamma relocation were not
enabled. Color detection, fruit inference, model weights and sensor tables
remain unchanged. Both detection paths continue to consume pre-Gamma AWB RGB.

The existing Gamma handles one pixel per clock and uses two ERAMs. Replicating
it for the four-pixel ISP would add eight ERAMs, while removing the display
instance recovers only two: 104 + 8 - 2 = 110, exceeding 108. Even a six-ERAM
packed implementation would consume all 108. This is incompatible with the
requested no-increase resource budget. The custom curve also needs model-input
accuracy validation before moving it in front of fruit inference.

## Acceptance Conditions

Reference: build/release, src-e5592e27b168, successful 2026-11-01 implementation.
The first attempt used the same CongestionHigh strategy and placement seed
1. A second attempt used seed 2 with identical RTL, clocks and acceptance
ceilings. Neither attempt produced an accepted final implementation.

| Metric | Maximum / requirement |
| --- | --- |
| Slice | 20,123 |
| LUT6 | 19,843 |
| Registers | 20,188 |
| ERAM | 104 |
| DSP | 39 |
| Final QoR wire length | 9,918,448 |
| Setup / hold failing endpoints | 0 / 0, both slow and fast corners |
| Setup / hold TNS | 0 / 0 |
| Open routed nets | 0 |
| Invalid / missing-path constraints | 0 / 0 |
| Placement top 1% average tile utilization | <= 95.50% |
| Placement tiles over 100% utilization | <= 5 |
| Placement maximum congestion level | <= 3 |

These measurements characterize this implementation; they do not guarantee
identical routing for different seeds, strategies, sources or tool versions.
The user's .al file currently selects the default physical strategy and is
preserved. The candidate experiments explicitly selected CongestionHigh.

## Candidate Reproduction

These commands describe the archived candidate, not the restored workspace.
Use an isolated checkout of commit 8dc675d and populate it with the files in
build/ae_awb_fix/candidate_source, preserving their relative paths. The current
production build driver deliberately no longer accepts the candidate-only
ProgrammingDirectory/MaxWireLength options after rollback. Use the archived
driver only in that isolated checkout. Copy the baseline reports there too.

```powershell
./sim/run_auto_exposure.ps1
./sim/run_awb_frame_adaptation.ps1
./sim/run_awb_confidence.ps1
./sim/run_isp_lighting_integration.ps1 -AllModes
./sim/run_isp_lighting_integration.ps1 -Diagnostics
./sim/run_isp_lighting_integration.ps1 -HoldRelease
./sim/run_video_fifo_frame_integrity.ps1 -RawSource
python verification/check_merge_readiness.py

./verification/run_image_quality_build.ps1 `
  -PhysicalStrategy CongestionHigh -PlaceSeed 2 -GenerateBit `
  -OutputDirectory build/ae_awb_fix/release `
  -ProgrammingDirectory build/ae_awb_fix/candidate_bit `
  -ResourceLimits @{slice=20123;lut6=19843;reg=20188;eram=104;dsp=39} `
  -MaxWireLength 9918448

./verification/compare_ae_awb_physical.ps1 -CandidateDirectory <build-snapshot>
```

The actual attempts reused the source-matched gate snapshot
anlogic_image_quality_72594f2bb0a84a18a1d637ea24377b17 in the local TEMP directory.
No candidate release manifest or programming bitstream was published. No board
programming was performed.

## Archived Candidate Regression

The following passes belong to the candidate source, src-6760003118aa. They
must not be interpreted as fixing the restored production AE/AWB behavior.

- The new production-mode hold test fails on the prior release AWB: a queued
  ratio commits when hold and SOF coincide. The repaired module passes all
  28 hold/recovery checks and 14,396 independently checked pixel values.
- Existing AWB adaptation passes 104 small frames and one 720p frame. The
  optional confidence regression passes 147 checks and two 720p frames.
- Each AE light-loop run passes 4,863 frames, 173 writes and 5,536 stability
  checks. Mean-only production and variable-count cases are both exercised.
- Video FIFO regression passes 6,512,640 written bytes and 3,686,400 read pixels,
  with zero underflows, overflows or pixel mismatches.
- All ten ISP display modes pass, each with three complete 720p frames and
  8,294,400 checked packed bytes. The separate diagnostic run checks 48 packets.
- The ISP hold-release run drops the warm frame whose hold is removed midway,
  retains unity gains through the following clipped frame, and recovers a
  candidate from the next complete clean frame. The two-stage ISP crossing is
  included; standalone AWB tests also check actual SOF gain commitment.
- The old ISP test expected nine detector pipeline clocks; the prior release
  independently reproduces its failure. The RTL documents ten clocks, observed
  one edge later by this test, so the expected color latency is now 11.
- The previous clipped pink background (255,170,190) is inside the current
  detector's 3R/4 secondary-channel bound. The hold integration scene uses
  (255,210,220), which remains clipped for AWB and is outside that bound.
  This is a test-scene correction; no detection thresholds are modified.
- The merge checker now recognizes only the exact AE/AWB hold substitutions.
  Unchanged modules bypass obsolete transformation patterns. Interfaces, the
  pixel datapath, protected algorithms and pin assignments remain checked.

## Physical Results

Physical acceptance NOT established. Candidate fingerprint: src-6760003118aa.

At synthesis: 46 fewer registers and 8 fewer distributed-RAM LUTs than the
reference synthesis.

Seed 1 was abandoned during routing, before final DRC or timing. Its placement
used 20,044 Slice, 19,779 LUT6, 20,104 registers, 104 ERAM and 39 DSP. Placement
top 1% average tile utilization was 94.03%, overfull tiles were 3 and maximum
congestion level was 2. Its last saved intermediate routing length exceeded
the baseline, but this was not a completed routed result. No release was
published. Evidence is saved in build/ae_awb_fix/seed1_aborted.

Seed 2 was also abandoned during routing. Its placement used 20,098 Slice,
19,780 LUT6, 20,113 registers, 104 ERAM and 39 DSP. Placement top 1% average
tile utilization was 95.13%, overfull tiles were 4 and maximum congestion
level was 2 (reference: 95.50%, 5 and 3). These are intermediate values, not
release acceptance.

At routing phase 1, iteration 20, seed 2 reported length 1.02007e7, about 2.85%
above the baseline final 9,918,448, with 2,050 resource-conflict locations
remaining. The attempt was stopped before final optimization, timing and DRC.
This is an early-rejection engineering decision, not a completed route result
or proof that every possible seed is infeasible. Final setup/hold slacks are
unavailable. Evidence is saved in build/ae_awb_fix/seed2_aborted.

The placed-database hold audit confirmed a normally timed meta-to-sync path
and normally timed AWB fanout. Its reports are in
build/ae_awb_fix/hold_timing_audit. Placed timing does not provide final routed
signoff. No clock period, payload bound or acceptance ceiling was relaxed.

Verification logs are preserved in build/ae_awb_fix/verification. The first
full-build snapshot is anlogic_image_quality_aa8131d191b94d04a122fb6811313e09;
the second is anlogic_image_quality_445e372587a942a9a17d1e7857db786f, both under
the user's local TEMP directory. Their source fingerprint is identical.

## Decision

The repair is functionally supported, but the user's combined requirements
of no increased implementation pressure and no timing violations have not
been demonstrated. Therefore it is not adopted. The production AE/AWB issues
remain unresolved; the original known-good physical implementation stays in
place. A future candidate must pass a complete routed comparison before use.
