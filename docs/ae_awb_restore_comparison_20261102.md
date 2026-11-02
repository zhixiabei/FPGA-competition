# Restored AE/AWB Source and Routing Comparison

## Restoration

At 17:33 local time on November 2, 2026, production sources were restored
to the AE/AWB routing-relief snapshot `src-48fcf269deaa`.
SHA256 comparison passed for all 273 source/project/constraint entries.
The recomputed source fingerprint is
`48FCF269DEAAA30B881309179F962911C80ABCDE277BB75BFAF797C2FAC892BB`.

AE, AWB, their top-level parameters and the SDC already matched this snapshot.
Only these later production edits needed restoration:

- `user_source/hdl_source/fruit_merged/fruitcnn128_core.v`
- `user_source/hdl_source/isp/red_target_detect_96.v`
- `user_source/hdl_source/target_frame_bridge.v`

Their exact previous contents and SHA256 values are preserved under
`build/restore_ae_awb_snapshot_20261102_173358/`, including
`restoration_manifest.csv`. Documentation and later verification utilities
were retained. This is an exact production-source restoration, not a claim
that every working-tree file has been reverted.

`verification/check_merge_readiness.py` passed after restoration. The
restored RTL is byte-identical to the candidate already covered by the AWB
confidence/frame/hold tests and all ten ISP integration modes. These tests
were not needlessly rerun for identical production source. No new physical
run or board programming was started by this restoration. No TD process
was present during inspection.

## Exact Functional Differences

The known routed baseline is `src-e5592e27b168`, completed November 1,
2026. Exactly five production files differ from the restored candidate:
`awb.v`, `auto_exposure_control.v`, `isp/isp_top.v`,
`design_top_wrapper.v`, and `anlogic_edge_osd.sdc`.

| Feature | Routed baseline | Restored candidate |
| --- | --- | --- |
| AWB confidence | Production `CONFIDENCE_ENABLE=0`; optional state/comparators largely optimized away | Enabled: spatial coverage, line/frame integrity, candidate consistency, capture/tracking limits, reacquisition and gain deadband |
| AE hold consumed by AWB | `CONFIDENCE_ENABLE && I_hold`, therefore disabled in production | Unconditionally honors `I_hold`; cancels pending work and rejects hold-contaminated frames |
| Cyan-neutral sample capture | Existing neutral gate requires R >= G/2 | Additional gate permits G/4 <= R < G/2, R >= 20, G/B agreement within G/8, and max channel 40..220 |
| Gain bounds | Final gain clamp already 128..1024 (0.5x..4x) | Same final clamp; confidence capture red upper bound explicitly 1024 instead of default 512 |
| Gain smoothing | Combinational smoothing on the SOF-to-pixel multiplier path | Store smoothed gains when division result is accepted; SOF selects prepared gains |
| Video delay | One 64x96 DRAM, shared read/write pointers | Four 64x24 DRAM banks, preserved local pointers; same total storage and 54-clock pixel/valid/last delay |
| AE average window | Six frames | Six frames normally, two for consistently extreme brightness/darkness |
| AE metering score | Capped RAW mean | Same mean plus bounded P95 highlight bias, at most 16 meter codes |
| AE release of AWB | Collection state releases hold, even before a stable complete window | Retain hold across changes/settling; release when a complete window needs no change or limits are reached |
| Histogram | 32-bin histogram enabled in source | Same histogram source and parameters; P95 is now actively consumed by AE |
| Clocks/CDC | Original clocks and bounds | Same clocks/bounds; only source-to-first-stage AE hold exception added |

The original AWB already had neutral-pixel filtering, a sequential divider,
frame-boundary gain updates, and gain smoothing. It was not a raw all-pixel
gray-world implementation. The original AE also already used frame averaging.
The new confidence mode and P95 use are behavior expansions beyond merely
repairing the ignored hold signal.

Cyan recovery addresses the demonstrated exclusion of red-deficient neutral
samples. It is not a measured sensor color calibration and does not establish
that every cyan cast has this cause. Neither source revision was newly
programmed onto the board in this work.

## Measured Physical Difference

All three columns use the same TD 6.2.168116, PH1P35MDG324 speed 3,
CongestionHigh placement, seed 1, unchanged clock periods, and committed
route effort `normal`. CongestionHigh does not itself imply high route effort.

| Placed metric | Routed baseline | Initial AE/AWB repair | Restored relief candidate |
| --- | ---: | ---: | ---: |
| Slice | 20123 (94.85%) | 20368 (96.00%) | 20317 (95.76%) |
| LUT6 | 19843 | 19966 | 20062 |
| Registers | 20188 | 20230 | 20297 |
| ERAM | 104/108 | 104/108 | 104/108 |
| DSP | 39/40 | 39/40 | 39/40 |
| Tiles above 100% estimated routing utilization | 5 | 7 | 7 |
| Top 1% tile average routing utilization | 95.50% | 96.42% | 95.55% |
| Placed setup WNS | +1.298 ns | +1.281 ns | +1.438 ns |
| Placed hold WNS | -0.275 ns | -0.284 ns | -0.273 ns |

The relief candidate adds 194 slices, 219 LUT6 and 109 registers over the
successful baseline. Free slices fall from 1093 to 899, a reduction of
about 18% in the already-small remaining slice capacity.

The hierarchy report localizes added hardware. Columns below are the
tool's `logic lut / ripple / seq` counts; they are not interchangeable
with whole-device LUT6 or additive physical slice counts.

| Placed module | Baseline logic lut/ripple/seq | Restored logic lut/ripple/seq |
| --- | ---: | ---: |
| AWB | 296 / 200 / 624 | 419 / 258 / 734 |
| AE controller | 105 / 28 / 53 | 116 / 46 / 57 |
| AE statistics CDC | 42 / 0 / 84 | 49 / 0 / 99 |
| RAW statistics | 71 / 66 / 113 | 96 / 66 / 116 |

The baseline gate netlist lacks AWB candidate-channel, column-count,
regional-sample and reacquisition buses present in the restored netlist.
This directly supports the conclusion that enabling the formerly disabled
confidence mode brought additional hardware into the design. P95 consumption
also retains five more payload bits across the three storage stages in the
AE statistics mailbox, consistent with its 15-register increase.

The local routing changes did achieve their narrow goals: the audited AWB
read-address bit went from 99 loads to 27 per bank, and the corresponding
gain-to-pixel multiplier path class went from eight to two logic levels.
They did not demonstrate successful whole-device routing. Lower fanout and
shorter logic depth are insufficient acceptance evidence on their own.

## Actual Outcomes and Cause

- Baseline: route command completed in 2235.44 seconds. Final routed,
  both-corner setup WNS +0.100 ns, hold WNS +0.020 ns, both TNS zero,
  zero failing endpoints and zero open nets.
- Initial repair: TD explicitly failed with `PHY-8080` at 14:47:11 on
  November 2 after 7300.45 seconds in the route command. Phase-one
  iteration 33 still had 2402 overused routing resources. The message
  identifies difficulty clearing routing conflicts. No final timing exists.
- Restored relief candidate: its saved log ends at phase-one iteration 34,
  15:18:07 on November 2, with 812 overused resources; no TD process or
  final routed timing exists. This log does not contain a final tool failure
  message, so its incomplete run must not be relabeled a completed failure.
  It also must not be treated as a successful candidate.

These counts are overused routing resources, not numbers of open nets or
percentages complete. Both an uncompleted route and a final timing failure
fail release acceptance, but they are different failure modes.

The supported engineering explanation is that the baseline was already
close to device capacity and had little final timing margin. Enabling
additional frame-control, qualification and metering logic changed the
netlist and the whole-device placement; the repair then had more overloaded
regions and failed detailed-route convergence under the same settings.
The build performs full placement/routing, so an AE/AWB-only source change
does not preserve the placement of CNN, DDR or other unchanged modules.

The exact network responsible for the last conflicts has not been proven.
There is no exported final conflicting-route map for these runs, and the
high-fanout CNN and detector nets also existed in the successful baseline.
Assigning sole blame to CNN, to the AWB RAM address, to host memory, or to
one newly enabled feature would exceed the evidence. Feature-isolated
physical builds would be required to attribute each contribution.

## Correction to the Implementation Approach

The earlier approach combined necessary hold/cyan fixes with enabling the
full confidence subsystem, P95 metering and a fast AE window, then added
local replicas. Its local simulation and timing improvements did not fulfill
the user's physical acceptance requirement. The restored source is retained
for an honest comparison, not represented as a routable release.

A more controlled follow-up should branch from the known routed baseline:
first preserve the original datapath, histogram and confidence setting while
repairing hold handling and the specific cyan-neutral capture exclusion;
then measure a complete route. Qualify fast exposure response, P95 feedback,
full confidence checks and local replication as separate changes, accepting
each only after routed setup/hold, DRC and CDC checks. This is a proposed
next experiment; it has not been substituted for the source the user asked
to restore.

## Evidence

Portable copies of the three snapshots' relevant RTL, manifests, resource
reports, placement timing/QoR and logs are in
`build/ae_awb_restored_comparison_20261102/{baseline,repair,restored}/`.
The baseline folder also contains the successful final routed reports.

The existing known-good bitstream remains unchanged, SHA256:
`BD86F2A74F522142AF5EC5AAD636B6B901B59BFFB97DE4A38227D506928D3C97`.
