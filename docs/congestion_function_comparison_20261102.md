# Functional Comparison, 2026-11-02

## Scope and Current State

This comparison uses the snapshot immediately before the current routing
relief changes, not the older November 1 release:

- Before: `src-699545ff2de6`, snapshot
  `C:/Users/1/AppData/Local/Temp/anlogic_image_quality_0bfbf708fb3b467d98f554d30f3d9354`.
- Current: `src-7d9c0ef0d1cc`, the production files in this workspace,
  matching the stopped `df1e78a70e3e45c783a48e6353ca9aa6` build snapshot.
- All 273 manifest-scoped files were checked by SHA256. Only the three
  production RTL files below differ. There are no added or removed files
  within that manifest scope. Project configuration and SDC are identical.
- The full routing run was stopped at the user's request around 17:06.
  Other placement probes have exited. No TD process remains, and no
  further run was launched after the stop request.

## Functional Changes

| Area | Before | Current | Observable behavior |
| --- | --- | --- | --- |
| CNN activation/control | One control/activation broadcast for 24 DSP lanes | Four same-cycle control copies, each driving six lanes | Model parameters, arithmetic, DDR addresses, requests, completion and cycle counts unchanged in differential tests |
| Single-shape detector | Shared row/capture enables | Five local row/capture enable banks | Color thresholds, geometry formulas, classifier FSM, boxes, shape IDs and output cycles unchanged in differential tests |
| Result frame bridge | Pending-slot bypass reads held CSI mailbox payload | Reads the already captured DDR-domain copy while writeback is active | Slot, nonce, frame ID, mode, ACK, reset and read/write ordering unchanged in differential tests |

The CNN retains 24 DSP lanes and the existing DSP register configuration.
No pipeline stage was added. The detector's extra controls equal
`r1_valid` and `r1_valid && r1_last` in the original row stage; clear/reset
priority and each destination's clear/hold behavior are preserved. The
bridge's differential test checks equality of the held source and local
copy during active writeback, including the actual pending-slot bypass.

Other production code is byte-identical to the selected baseline:
AE/AWB, display effects, HDMI/OSD, camera input, model configuration,
DDR interfaces, checkout/scale/voice, buttons and diagnostic modules.
This preserves earlier fixes already present before this routing task;
it does not claim comparison with an earlier, unselected release.

## Existing Validation Rechecked Against Current Files

| Validation | Evidence | Result |
| --- | --- | --- |
| CNN, portable and vendor ERAM/DSP | 25 scenarios, 63,720 cycles, all 24 DSP lane inputs and external transaction/cycle outputs | PASS |
| Detector direct engine, portable and vendor | 64x32 and 1280x720 parameters, each 49,015 cycles and 672 captures, reset/clear/cancel/abort/bubbles | PASS |
| Detector complete RGB flow, portable and vendor | 320x240, each 2,440,809 cycles, 22 cases, 60 results and 144 checks | PASS |
| Frame bridge, portable and vendor | 11,710 DDR cycles, 64 frames, pending bypass, same-slot collisions, cached-write priority and queue configurations | PASS; latency delta 0 |
| Existing top-level frame-alignment regression | 36 writes/reads/display samples, 34 result checks and 35 invalidations | PASS |

The changed RTL source hashes match the files used in these completed
tests. Reference RTL was checked against the selected pre-change snapshot
after accounting only for module renaming and line-ending normalization.
No simulation or physical run was started for this final read-only review.
Archived evidence: `build/congestion_relief/validation/`.

## Physical Results and Limits

The current placement uses 20,421 Slice, 20,121 LUT6, 20,338 FF,
104 ERAM and 39 DSP, versus 20,317 / 20,062 / 20,297 / 104 / 39 before.
These changes alter implementation resources, not intended behavior.
Local CNN/EOF fanout reduction was verified in the placed netlist, but
global routing improvement has not been demonstrated.

The stopped route did not produce final both-corner setup/hold acceptance,
a validated candidate bitstream or a new board test. Existing passing RTL
tests provide finite-scenario equivalence evidence, not exhaustive formal
proof. In particular, the 1280x720 detector test drives the row engine;
the complete pixel-flow test uses 320x240. Unchanged source code alone
does not establish final hardware timing.

The selective-sign CNN alternative in
`build/congestion_relief/selective_broadcast/` passed its own tests but
was not adopted: its placement had 12 overused tiles versus seven for
the current implementation. Macro-congestion and strategy-2 probes also
did not modify production RTL or become a released implementation.
