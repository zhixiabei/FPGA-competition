# Local Routing Relief, 2026-11-02

## Stopped Status

At the user's request, the full routing process (PID 28880, started at
16:04:34) was stopped at approximately 17:06 on November 2, 2026. The
build driver's nonzero exit is an intentional termination, not a new
tool-reported routing failure. The last completed routing iteration was
19 with 4,571 overused resources. No final routed timing or new bitstream
was produced. The independent placement probes have exited, and no TD
process remains. No new physical run is scheduled.

The production source still matches all 273 entries of the full-group
candidate manifest (`src-7d9c0ef0d1cc`). Relative to the pre-change manifest
(`src-699545ff2de6`), only the three RTL files listed below differ. The
selective-broadcast alternative remains an isolated experiment and has
not replaced production RTL. Functional comparison is recorded in
`docs/congestion_function_comparison_20261102.md`.

## Scope and Acceptance

This candidate changes only three production RTL files relative to
`src-699545ff2de6`: `fruitcnn128_core.v`, `isp/red_target_detect_96.v`, and
`target_frame_bridge.v`. The source manifest comparison confirms that the
project, clocks, SDC, vendor IP, AWB, and all other production sources are
unchanged. No board programming is part of this experiment.

Acceptance requires exact cycle behavior in differential regressions,
preserved local drivers in the mapped design, completed routing with no
open nets/DRC errors, and nonnegative setup/hold slack with zero failing
endpoints at both slow and fast corners under the existing constraints.
Functional simulation or positive intermediate slack is not final acceptance.

## RTL Changes

1. CNN: retain four identical copies of the existing term-stage controls
   (`valid`, `first`, `is_padding`, three-bit `offset`). Each copy feeds the
   activation mux and enables for six of the 24 DSP lanes. Register updates,
   reset behavior, term consumption, MAC latency, counters and memories are
   unchanged. There are 18 additional logical FFs before mapping.
2. Detector: generate five row-valid and final-row controls at the existing
   r1 boundary. They drive the statistics, bounds, x moment, y moment and
   diagonal-coordinate register banks. The historical 223-load
   `frame_done_n` net is a snapshot capture enable, not the registered
   `frame_done` output. The new enables target that actual capture fanout.
   There are ten additional logical FFs. Reset, clear/hold behavior,
   classifier state machine and output timing remain unchanged.
3. Frame bridge: during active result writeback, the pending-slot read
   bypass uses `S_last_result_payload`, already captured in the DDR domain.
   The mailbox protocol guarantees equality with the held source payload
   while writeback is active. No extra storage or clock cycle is introduced.

For the detector, `bank_valid[k] = r1_valid` and
`bank_final[k] = r1_valid && r1_last`: the original r1 stage captures
`r0_last` whenever `r0_valid` is asserted. Invalid bubbles mask stale last
values. Both original and replicated controls clear on reset/I_clear.
Every moved destination retains its original reset, clear, enable and RHS.

## Verification Evidence

- CNN: 25 numerical scenarios, 63,720 cycles; all external ports, cycle
  counters, and the actual inputs of all 24 DSPs match the pre-change core.
  Both portable models and Anlogic ERAM/DSP models pass. Final vendor run:
  `C:/Users/1/AppData/Local/Temp/anlogic_fruit_numeric_fdbf6d18796d4397b64ac26e32a38b27`.
- Detector: direct differential cases use 64x32 and production 1280x720
  geometry, comparing all moved work/snapshot registers and outputs.
  Each covers 49,015 cycles, 3,249 rows, 672 snapshots, clear/EOF collisions,
  classifier cancellation, aborts and asynchronous reset. The complete RGB
  scene differential covers 2,440,809 cycles and 22 cases under both portable
  and vendor models. Manifest:
  `C:/Users/1/AppData/Local/Temp/anlogic_detector_row_routing_964583567e7e4288bfd24e49d05fcf24/validation_manifest.json`.
- Bridge: portable and vendor models pass against the pre-change HEAD,
  including an active-mailbox equality invariant, pending-slot bypass read,
  cached-result write priority, same-slot simultaneous read/write, and
  queued reads. The directed scenario checks 11,710 DDR cycles.
- Top-level frame alignment passes 36 writes, reads and display samples,
  34 result checks and 35 invalidation checks. Its isolated video-mode
  fixture needed existing-interface updates (AE parameter, checkout stub,
  RAM model and calibration-complete stimulus); production RTL was unchanged.
- `verification/check_merge_readiness.py` passes, including project source
  inventory, named interfaces, pins and the narrowly scoped bridge change.

## Physical Validation

Candidate source identity: `src-7d9c0ef0d1cc`.
Synthesis snapshot:
`C:/Users/1/AppData/Local/Temp/anlogic_image_quality_a60a7a9e89c047548efe360d4e2383bd`.

Synthesis completed successfully. Against the same-stage baseline,
primitive registers increased from 20,595 to 20,628 (+33), and logic LUTs
from 30,082 to 30,237 (+155). These are pre-placement figures, not packed
physical Slice/LUT6 counts. ERAM remains 104 and DSP remains 39.

`verification/audit_congestion_relief.tcl` checks 24 CNN and ten detector
preserved control registers and emits fanout reports from an explicit
snapshot. It never queries or modifies a live routing process.
All 34 preserved registers were found in the candidate gate database.

`verification/check_cnn_broadcast_netlist.py` parses the actual 24 DSP
activation/enable connections and fails on missing lanes, unknown syntax,
cross-group wiring or inconsistent bit widths. Gate audit passed:

| Connection | Baseline load pins | Candidate load pins |
| --- | ---: | ---: |
| CNN activation sign | 384 on one net | 96 on each of four nets |
| CNN DSP enable | 96 on one net | 24 on each of four nets |
| Detector original EOF capture | 223 | 14 plus independent 56/42/32/31/48 |
| Detector input row stage enable | 134 | 140 |
| Detector restart predicate | 233 | 232 |
| Detector collect predicate | 235 | 234 |

The detector predicate net names change between mappings; compare LUT
function and connected loads, not the numerical synthesized suffix.
CNN gate connectivity evidence: `build/cnn_broadcast_netlist_audit_20261102.json`.
Preservation/fanout evidence: `build/congestion_relief/gate_audit/`.

At 16:04 local time the source-matched full physical build started in
`C:/Users/1/AppData/Local/Temp/anlogic_image_quality_df1e78a70e3e45c783a48e6353ca9aa6`.
It uses CongestionHigh, seed 1, route effort routability, and the existing
resource limits (Slice 20,600; LUT6 20,400; FF 20,700; ERAM 104; DSP 39).
The pre-change retry (TD PID 17308, started 15:10:36) was stopped after
conflicts rose from 3380 to 3519, 3793 and 4088. Its logs are retained.
Only the new candidate proceeds to routing. Its release destinations are
`build/congestion_relief/release` and `build/congestion_relief/candidate_bit`.

Placement completed at approximately 16:10. Packed resources remain within
the unchanged resource ceilings, but the global placement estimates have
not improved:

| Placed metric | Pre-change baseline | Candidate |
| --- | ---: | ---: |
| Slice | 20,317 (95.76%) | 20,421 (96.25%) |
| LUT6 | 20,062 | 20,121 |
| FF | 20,297 | 20,338 |
| ERAM / DSP | 104 / 39 | 104 / 39 |
| Estimated wire length | 3,276,905 | 3,573,543 |
| Top 1 percent average congestion | 95.55% | 95.87% |
| Tiles above 100 percent | 7 | 7 |
| Maximum congestion level | 2 | 3 |

Read-only inspection of the candidate `system_place.db` confirms that
physical optimization retained all four CNN broadcast groups: each group
has 96 activation-sign load pins and 24 DSP enable load pins, restricted
to its six lanes. All other nonconstant activation nets are also confined
to one group. The detector EOF network retains the 14+56+42+32+31+48
partition; the five data banks occupy distinct areas, with each EOF bank
spanning at most eight columns and six rows. Evidence:
`build/congestion_relief/placement_audit/cnn_summary.json` and
`build/congestion_relief/placement_audit/detector_summary.json`.

At 16:15 the router was in Stage 2.5.1.4, phase-one rip-up/reroute.
Overused-resource counts fell from 45,405 before rerouting to 23,065,
17,249 and 15,396 in the first three iterations. This is progress within
an incomplete route, not demonstrated improvement over a completed
baseline. The earlier initialization setup/hold violations are likewise
intermediate; acceptance depends on the final both-corner reports.

Full routing was subsequently stopped at the user's request. Final timing
acceptance and any wall-time improvement remain unverified. No completed
candidate bitstream is claimed.

## Selective Broadcast Screening

The full-group candidate remains the production RTL while this alternative
is screened in `build/congestion_relief/selective_broadcast/`. It retains
the four identical control banks and local activation sign bits, but shares
the eleven lower activation bits across all lanes. No register boundary,
cycle count, algorithm, reset or DDR behavior changes.

Both portable and vendor ERAM/DSP differential regressions pass all 25
scenarios and 63,720 cycles against the current full-group candidate. The
reference chain to the original pre-change implementation is recorded in
`selective_broadcast/validation.json`; the new trial is not represented as
a direct rerun against the original reference.

Selective source identity: `src-33e1003c9a4f`; synthesis snapshot:
`C:/Users/1/AppData/Local/Temp/anlogic_image_quality_2d314bcdb79d4f1b91dc5c0ddcc18ccb`.
Synthesis and the explicit `--activation-layout sign-only` netlist audit
pass. Against the full-group gate netlist:

| Gate metric | Full-group candidate | Selective candidate |
| --- | ---: | ---: |
| Row cache output load pins | 384 | 120 |
| Activation-sign load pins per group | 96 | 96 |
| DSP enable load pins per group | 24 | 24 |
| Lower activation bit load pins | 6 per group | 24 shared |
| Total F7 resources | 190 | 157 |
| Total primitive LUT report | 30,237 | 30,111 |
| Total primitive registers | 20,628 | 20,628 |

All 96 row-cache source bits have exactly one ERAM output driver. In the
selective candidate the 88 lower data bits each have one load; the eight
source sign bits each retain four loads. The stricter sign-only audit
requires eleven distinct shared lower-bit nets, four disjoint sign nets,
and four disjoint enable nets across the actual 24 DSP instances.

These are synthesis measurements, not physical Slice savings. For example,
the hierarchy-specific core logic-LUT column rises from 1,456 to 1,502;
it is a different metric from the total primitive-LUT count and must not
be substituted for final placed resource usage.

The isolated CongestionHigh/seed-1 placement finished at about 16:48 in
`build/congestion_relief/selective_broadcast/place_default_v3/`:

| Placed metric | Full-group candidate | Selective candidate |
| --- | ---: | ---: |
| Slice | 20,421 | 20,422 |
| LUT6 | 20,121 | 20,077 |
| FF | 20,338 | 20,337 |
| Estimated wire length | 3,573,543 | 3,416,392 |
| Top 1 percent average congestion | 95.87% | 97.26% |
| Tiles above 100 percent | 7 | 12 |
| Maximum congestion level | 3 | 3 |
| Placement setup WNS | 0.572 ns | 1.036 ns |
| Placement hold WNS | -0.273 ns | -0.281 ns |

This is a mixed result with worse congestion, so the selective candidate
has not replaced production RTL and has not proceeded to detailed routing.
An independent placement-only probe of the full-group candidate with
`macro_performance=macro_congestion` started at about 16:50. It preserves
the same gate database, original constraints, CongestionHigh and seed 1.

At 16:55 the full-group detailed route had reached iterations 16 through
19 with overused-resource counts 3,803, 3,992, 4,235 and 4,571: three
successive increases. It is not converged, and no speedup or timing-closed
result is claimed.

The macro-congestion placement-only probe completed with 20,381 Slice,
estimated wire length 3,406,030, top-1-percent average congestion 96.00%,
six overused tiles, and maximum level 3. A separate `pr_strategy=2` probe
also completed; its reported placement metrics equal the original
full-group placement. Both probes are screening results only. Neither
proceeded to detailed routing before the user's stop request.

## Bridge CDC Evidence

Gate database comparison at 16:06 used the pre-change `0bfbf708...` snapshot
and candidate `a60a7a9e...` snapshot. Both queries resolve 66 mapped registers
for `S_result_payload[0:67]`, 25 for bits 68 through 92, and 75 mapped
`S_read_payload` registers. The baseline has 66 body and three mode-bit
paths directly from the CSI mailbox to the DDR read payload, under the
broad 100 ns clock-pair limit. The candidate has no timing path for either
source group to the read payload; TD emits its no-path warning and does
not create those empty reports. Thus the mapped candidate removes the
direct data bypass, including the mode-bit paths.

The retained source-mailbox to `S_last_result_payload` crossing explicitly
uses the existing 20 ns bound; the broad 100 ns rule is reported as
shadowed. Its five worst reported endpoints have synthesized setup slack
of at least 19.181 ns. The local DDR cache-to-read paths use the normal
15 ns DDR clock period, with worst reported synthesized slack 8.422 ns.
These are gate estimates, not placement or final timing acceptance.

The mailbox holds its payload until the synchronized ACK. The local copy
is captured on the initial message, and the active-writeback state blocks
another initial message until writeback completes. The differential
regression checks `active => local payload == source payload` after reset
release, including same-edge writes and reads with pending queues enabled
and disabled. No SDC change or relaxed timing exception was introduced.
Evidence and reusable diagnostics: `build/congestion_relief/bridge_audit/`.
For a later snapshot, the common script accepts `database_name` and
`timing_mode` overrides before it is sourced.
