# Single-target shape contour repair (2026-11-01)

## Scope and reproduced failure

Only `red_single_shape_engine` in
`user_source/hdl_source/isp/red_target_detect_96.v` changes in production RTL.
Color segmentation, shared shape classifier thresholds, target association
rules, multi-target selection, clocks and constraints are unchanged. The
frame-rate association/display ALU now loads its operands before executing;
its arithmetic and decision rules are preserved.

The prior row collector stopped at the first internal gap and discarded the
right-hand segment. It also marked any row whose color count differed from
its span as malformed. A small internal highlight could therefore invalidate
a single visible object's shape and produce UNKNOWN after the label hold
expired. Merely ignoring the bad flag would leave incorrect area and moments.

The frozen baseline (`1513c35`, detector SHA256
`7F520CA0F8D24222111B5E94102C5D89722104AB2433A6327DB3DEBA940B482B`)
fails the new RGB regression on frame 3: an 81 x 81 red square with a
9 x 9 white interior hole returns UNKNOWN with `bad=1`.
Evidence: `build/shape_contour_fix_20261101/baseline_probe`.

## Repair rules

- Rejoin a short horizontal internal gap only when the previous occupied
  row supports both sides. Maximum gap width is 16 pixels.
- Within-beat missing pixels also require previous-row support. Invalid
  population counts still invalidate the shape.
- Missing pixels per row must not exceed
  `min(16, max(2, floor(row_span / 4)))`.
- Reconstructed pixels across the contour must not exceed
  `floor(raw_colored_area / 32)`.
- At most 16 consecutive rows may require repair. A gap must close before
  the component ends; an open crack remains invalid.
- Keep raw colored area for target qualification. Use the repaired row span
  consistently for shape area, moments and outside perimeter. Existing
  clipping, malformed-row, overflow and split/merge guards remain active.

This is bounded restoration of an outside silhouette, not arbitrary hole
filling. Large holes, rings, U shapes, excessive missing area and long/open
cracks remain UNKNOWN. Objects lost by color segmentation or by the existing
single-target acquisition policy are outside this change.

## Timing structure

Row connectivity is tested before endpoint multiplexers. Component
connectivity is captured with the existing row metadata stage, alongside the
existing size qualification. Input rows are separated by a complete scanline,
so the preceding accumulation is stable at that capture. This row change adds
no result stage or frame latency. The regression checks both connectivity expressions
against their original forms on every consumed row.

The gate timing report also identifies a 10-level path from `smooth_index[0]`
through the shared operand mux and adder to `association_ok`. Its data delay
is 9.158 ns, maximum fanout 90, and setup slack **+0.434 ns**. This is a long
path with positive slack, not a demonstrated cause of physical congestion.
The current RTL registers the selected operands and carry before arithmetic.
Each of the 32 association and 22 smoothing operations has a load cycle and
an execute cycle, adding 54 clocks per frame without changing pixel intake.
Clear, abort and a superseding completed frame discard a pending operation.
The change adds 28 registers at 720p before optimization; no reduction in
area, fanout or routing congestion is claimed without implementation reports.

## Reproduction

Run from the project root:

```powershell
& './sim/run_single_shape_contour.ps1' -Mode Both
& './sim/run_single_shape_contour.ps1' -Mode Vendor -Width 1280 -Height 720 -ProductionProbe -TimeoutSeconds 900
& './sim/run_single_color_shape.ps1' -Mode Portable -TimeoutSeconds 600
& './sim/run_single_color_track_robust.ps1' -Mode Portable -TimeoutSeconds 600
& './sim/run_single_target_switch.ps1' -Mode Both
& './sim/run_single_shape_contour.ps1' -Mode Portable -ProductionProbe
& 'D:\python\python.exe' './verification/check_merge_readiness.py'
```

The contour runner snapshots the RTL and testbench, records SHA256 hashes,
and checks simulator completion and a PASS marker. `-RtlSource` selects a
frozen reference; `-OutputDir` must name a new directory.

The full contour suite exercises square, rotated square, circle and triangle
in red, green and blue, acquisition with a hole already present, repeated
hole frames, all four input-lane alignments, input bubbles and line blanking.
It compares the raw classifier result and repaired descriptor with the clean
silhouette, independently of temporal label retention. Negative cases include
rectangle, ellipse, ring, U shape, large holes, long/open cracks and excessive
aggregate repair. A 9 x 16 hole is accepted and a 9 x 17 hole is rejected.

The focused 720p suite tests high-coordinate square, rotated square, circle
and triangle in red, green/blue squares, and two invalid contours. It is not
the complete 320 x 240 suite at 720p.

## Contour-only evidence before the ALU change

Contour-only v4 RTL SHA256:
`8416F30AC1E50CA771CED9E32FE234EE8EDB706A3910E646B98178D50BD4B158`.
Contour-only v4 testbench SHA256:
`7CF21B08B5A2A008F7798539872723F7B31C5D3F9C4ABE956678C3E0AD074BC3`.

Evidence directories below are relative to
`build/shape_contour_fix_20261101/` and contain source snapshots and logs.

| Check | Result | Evidence |
| --- | --- | --- |
| Full contour, Portable | PASS: 155 frames, 22 cases, 232 checks | `contour_v4` |
| Full contour, Vendor | PASS: 155 frames, 22 cases, 232 checks | `contour_v4` |
| Focused 1280 x 720, Vendor | PASS: 22 frames, 8 cases, 20 checks | `production720_v4` |
| Existing geometry, Portable | PASS: 60 results, 22 cases, 144 checks | `geometry_v4` |
| Existing robust tracking, Portable | PASS: 103 results, 227 checks | `tracking_v4` |
| Existing mode switch, Portable and Vendor | PASS: 22 results/checks per variant | `switch_v4` |
| Static source/project/interface checks | PASS | `check_merge_readiness.py` |

All simulation variants above completed with zero simulator errors
and warnings. The full contour and 720p manifests match the v4 RTL and
testbench hashes shown above. `git diff --check` also passes.

Whole-project synthesis completed with Tang Dynasty v6.2.168116 for
PH1P35MDG324. Source version: `src-9728d33f8e02`. Its input manifest differs
from the frozen baseline only in the detector file. Reports and the v4
detector snapshot are archived in `synthesis_v4`.

| Synthesis estimate | Frozen baseline | Contour-only v4 |
| --- | ---: | ---: |
| LUT | 29686 | 29905 |
| Registers | 19459 | 19518 |
| Estimated slices | 22986 | 23171 |
| ERAM | 100 | 100 |
| DSP | 39 | 39 |
| Global setup WNS, ns | +0.141 | -0.072 |
| Global hold WNS, ns | +0.114 | +0.114 |

The v4 detector clock domain (`MIPI_RX_BYTE_CLK`, 9.660 ns) has
setup WNS +0.196 ns and zero setup-violating endpoints. Global setup
WNS is still -0.072 ns, with STNS -0.643 ns in the unchanged CNN
`preprocess/sample_index -> cached_byte` and `core/kernel -> ky` paths.
This is a limitation of this v4 whole-project synthesis result; it is
not evidence of whole-project timing closure or a claim that the baseline
already had those violations. The synthesis script's PASS marker means
the synthesis command completed, not that all timing checks passed.

STA coverage is 94.23%. No detector warnings or inferred latches were reported;
vendor DDR warnings remain. Gate-level slice counts are tool estimates before
placement optimization and exceed the device count in both versions. They
must not be treated as final physical usage or proof of fit.

Earlier `v2`/`v3` logs belong to intermediate RTL. They helped expose and fix
detector timing paths and are not substituted for the `v4` evidence.

## Stopped implementation and congestion evidence

A subsequent full build of the same v4 source was stopped during routing at
the user's direction. It was not a successful implementation and produced
no bitstream. Existing reports are preserved in `placement_stopped_v4`.
No further synthesis/place/route was started for the ALU change.

- Placement uses 20,189 slices (95.16%), 100 RAMs and 39 DSPs.
- The placement congestion window is (7,59) to (19,65). There are 21 tiles
  above 100% routing utilization; top 1% tile average utilization is 97.89%.
- Placement global setup/hold WNS is +1.305/-0.284 ns. The MIPI domain's
  setup/hold WNS is +1.761/-0.202 ns. These are pre-route estimates.
- The first routing rip-up/reroute phase took 1143.996 seconds. The following
  intermediate timing update reported setup WNS -6.727 ns. A later reroute
  phase was still iterating when stopped. None of these are final signoff.

Sampled timing paths locate raw-color FIFO pointer and DDR control cells in
the congestion window. They do not enumerate all congested nets or establish
which module caused the congestion. The shape ALU gate path is a separate
logical observation; it has not been mapped to the physical hotspot. The
saved artifacts contain a gate database but no placed/routed database, so
an exhaustive hotspot-net attribution is not available from this snapshot.
Do not change DDR, FIFO crossings, clocks or timing exceptions based only on
these sampled locations. The next physical diagnosis requires the congested
net/pin list and placement map for this window, before choosing a structural
or placement change. Repeating the full flow is not that diagnosis.

## Current ALU change and local verification

Current RTL SHA256:
`BAA753ECB4CE425D3AC228C963DCA6F06DCDBC455507EA4D74231C6E7F15D730`.
Current contour testbench SHA256:
`8EF9D07A896FDE5243A42559CD1ECD6B8E538334B8E4931FA536461FF1BCAC0D`.

| Check | Result | Evidence |
| --- | --- | --- |
| Focused 320 x 240 contour, Portable | PASS: 22 frames, 8 cases, 20 checks | `alu_pipeline_probe_v2` |
| Registered arithmetic versus original formula | PASS: all 1188 executed operations; exactly 54/frame | `alu_pipeline_probe_v2` |
| Existing robust tracking, Portable | PASS: 103 results, 227 checks | `alu_pipeline_tracking` |
| Existing mode switch, Portable | PASS: 22 results/checks | `alu_pipeline_switch` |
| Static source/project/interface checks | PASS | `check_merge_readiness.py` |

These final local simulations completed with zero errors and warnings. The
first probe (`alu_pipeline_probe`) failed during testbench elaboration because
the installed simulator rejects a hierarchical parameter reference through a
generate block. The testbench now calculates its width from W/H; the corrected
probe above passed. No production RTL changed to address that testbench error.

The complete contour suite, vendor simulation and 720p suite above are v4
evidence and have not been rerun for the ALU change. Current-source synthesis,
final routed timing, physical congestion improvement, bitstream generation
and camera/board operation remain unverified. No firmware was programmed.
