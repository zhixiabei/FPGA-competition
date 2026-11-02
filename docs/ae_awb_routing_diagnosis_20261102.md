# AE/AWB Routing Diagnosis, 2026-11-02

## Scope and State

The user requested that the current routing continue and that the whole
design be inspected before applying further congestion changes. This pass
only reads completed placement databases and logs. It does not modify RTL,
constraints, the running build, or either bitstream release.

Current source: `src-08947f93c06a`. Baseline: `src-e5592e27b168`.
Both use TD 6.2.168116, PH1P35MDG324 speed 3, CongestionHigh, place seed 1.
The build script calls full `place` and `route`, without ECO or incremental
options. A change confined to AE/AWB therefore still rebuilds whole-device
placement and routing.

Current build snapshot:
`C:/Users/1/AppData/Local/Temp/anlogic_image_quality_26dee702c23143e59215378515a4db87`.
The router process is PID 63164, started at 12:39:09 local time. CPU time
increased during inspection from 2161.25 to 2569.28 seconds. The last observed
completed routing iteration at 13:14:33 local time was iteration 24.

## Progress Comparison

These are Phase 1 rip-up/reroute iterations, not percentages of total work.

| Iteration | Baseline conflicts | Current conflicts |
| --- | ---: | ---: |
| 20 | 370 | 2466 |
| 21 | 290 | 2397 |
| 22 | 225 | 2330 |
| 23 | 197 | 2348 |
| 24 | 114 | 2081 |

The current run is doing work, but convergence is materially slower than the
successful baseline. Iteration 24 alone took 330.12 seconds. Its routing
length has increased to 11,426,900 at iteration 24. This is an intermediate
estimate, not the final QoR wire length.
The baseline cleared Phase 1 conflicts at iteration 39, then performed
additional timing/routing phases. Its entire routing optimization stage took
2119.93 seconds. That history is not an ETA for the current run.

## Placement Resources

| Metric | Baseline placed | Current placed |
| --- | ---: | ---: |
| Slice | 20123 / 21216 (94.85%) | 20368 / 21216 (96.00%) |
| ERAM | 104 / 108 | 104 / 108 |
| DSP | 39 / 40 | 39 / 40 |
| Top 1% tile average utilization | 95.50% | 96.42% |
| Tiles over 100% utilization | 5 | 7 |
| QoR congestion window | [9,9]-[16,19] | [9,11]-[18,20] |

Current physical LUT6 is 19966 / 21216 (94.11%), and register use is
20230 / 42432 (47.68%). There are 848 unused slices, but only 232 slices
remain below the current build's 20600-slice acceptance ceiling. Spare FF
count does not guarantee available packing or local routing capacity.

## Whole-Design Net Inspection

The independent TD process imported the completed `system_place.db` and
reported 62954 nets. After excluding clocks, constants and hardwired/internal
nets, 40711 remained for the fanout inventory.

| Network | Baseline loads | Current loads | Interpretation |
| --- | ---: | ---: | --- |
| CNN `mux341_syn_24` | 384 | 384 | Activation sign bit distributed to 24 DSP lanes |
| CNN `mux332_syn_180` | 120 | 115 | Existing CNN datapath/control network |
| CNN `activation_cache_valid_3_i_syn_2` | 110 | 110 | Existing cache control fanout |
| Detector `frame_done_n` | 223 | 223 | Frame-control distribution |
| Detector `snap_bad_n3_syn_6` | 205 | 207 | Snapshot-control distribution |
| AWB `video_read_address[3]` | 99 | 99 | Existing video delay-memory addressing |
| `u_isp_top/awb_hold_sync` | absent | 8 | New AE/AWB hold synchronizer output |

CNN sign-bit connectivity was checked explicitly: its loads are the sign
extension inputs `xa[11..26]` on 24 `DSPSIOU` lane instances. The source RTL
is `fruit_merged/fruitcnn128_core.v:199`; the DSP wrapper extends the activation
to 27 bits in `resnet/resnet_ph1p_dsp.v`. The current driver is at grid [22,16].
Packed cell names do not necessarily name the RTL function of every output
inside that slice; load connectivity was used to identify the signal.

There are also reset networks with 7784, 902 and 642 load pins. High fanout
alone does not establish that these are the remaining conflicting routes.
Reset/DDR initialization semantics need separate review before any changes.

Sampling physical grids x9..18,y11..20 found 706 SLICE cells: 687 belong to
the CNN core, 16 to its surrounding system, two to checkout, and one to DDR.
This is useful placement context. The QoR window's coordinates have not been
independently proven identical to physical grid coordinates, so this sample
must not be presented as an exact list of live congested cells.

`report_congestion -step place` and `report_route_status -fanout_stat` did not
return congestion/route data after importing this placement DB. Cell and net
queries did work. No live detailed-routing heatmap or list of the remaining
2081 conflicts was obtained. These findings identify optimization candidates,
not a demonstrated single root cause.

## AWB Timing Candidate

Placed timing identifies a path from gain state through smoothing arithmetic
and the first-pixel gain selector into the pixel multiplier:

- Begin: `u_isp_top/u_awb/add7_syn_61.clk`, near grid [29,54].
- End: `u_isp_top/u_awb/mult1_syn_165.mult_p[44]`.
- Setup slack: +1.342 ns at placement.
- Data delay: 8.032 ns, including 5.570 ns cell and 2.462 ns net delay.
- Logic depth: six adders, one LUT3 and one DSP multiplier; max fanout eight.

This is primarily an arithmetic-depth candidate. It is not evidence that an
AWB high-fanout net causes global congestion. Source: `awb.v:284..312`.
The current placed overall setup/hold WNS is +1.281 / -0.284 ns. Placement
timing is intermediate; neither this result nor early router `crit=0` meets
the final timing acceptance requirement.

## Proposed Order of Work

1. Let the current router finish or report its own failure. Preserve its
   complete result for comparison; do not stop on routing-length growth.
2. On a separate candidate, first test targeted physical replication of the
   CNN activation sign broadcast. The installed TD documentation lists
   `phys_opt -force_replication_on_nets`; verify its support for this actual
   combinational driver and inspect resulting placement and fanout. A few
   local drivers could reduce the distance and load per driver without
   adding DSPs or algorithmic cycles. Actual resource cost and benefit must
   be measured. Do not apply broad replication to every high-fanout net.
3. If AWB remains timing-critical, prepare/register smoothed gains during
   frame blanking so SOF selects an already computed value. Budget tens of
   FFs initially. Prove exact SOF/first-pixel behavior, pending-result timing,
   hold cancellation and the existing 54-clock pixel/valid/last contract.
4. If route evidence points to frame-control or AWB delay-memory addressing,
   evaluate local same-cycle control copies in the relevant banks. Check
   packed register/LUT cost and distribution, not only RTL register count.
5. Compare each isolated candidate against the unchanged current source.
   Require completed routing, no open nets/DRC failures, both-corner setup
   and hold WNS >= 0, TNS = 0, no failing endpoints, and effective CDC bounds.
   Keep the existing clocks and specific timing exceptions unchanged.

The first physical experiment should stay small enough to fit the existing
20600-slice / 20400-LUT6 / 20700-register / 104-ERAM / 39-DSP ceilings.
No congestion optimization from this list has been applied by this inspection.

## Evidence

Artifacts under `build/ae_awb_repair/placement_diagnosis`:

- `console.log`: imported placement queries, DSP placement, sampled grids.
- `all_nets.log`, `net_fanout.csv`: full net reports and parsed fanout inventory.
- `focus.log`, `baseline_focus.log`: explicit connectivity comparisons.
- `window_cells.csv`, `summary.json`: parsed grid membership and summaries.

Scripts under `build/ae_awb_repair`: `inspect_placement.tcl`,
`inspect_nets.tcl`, `inspect_focus.tcl`, `summarize_placement.ps1`.
These diagnosis scripts issue no `place`, `route`, `phys_opt`, `export_db`,
or `bitgen` commands.
