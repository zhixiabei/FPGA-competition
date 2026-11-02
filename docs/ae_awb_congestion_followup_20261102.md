# AE/AWB Congestion Follow-up, 2026-11-02

## Running Stage and Previous Failure

At 15:09 local time, the routing-relief candidate was still running as PID
49960. The latest completed iteration was 33, with 744 conflicting routing
resources (`over cnt`), following 725 at iteration 32. These counts are not
open-net counts or a completion percentage.

Its stage is `Stage 2 | Detail Routing`, then `Stage 2.5 | Routing
Optimization`, `Phase 1`, `Stage 2.5.1.4 | Rip-up And ReRoute`.
Global routing (Stage 1) has finished. Subsequent detailed-routing phases,
Stage 3 Hold Fix, Stage 4 Report Route QoR, Stage 5 Routing DRC, and final
timing acceptance have not finished. The successful November 1 reference
ran through Phase 11; that is historical evidence, not a required phase
count or an ETA for this candidate.

The earlier repair in snapshot `anlogic_image_quality_26dee702c23143e59215378515a4db87`
failed at 14:47:11 after iteration 33 with 2402 conflicts. Its `PHY-8080`
error explicitly suggested a different strategy or `set_param route effort
routability`. This was a tool-reported routing failure.

## Reconstructed Placement Congestion

Importing `system_place.db` alone leaves `report_congestion` unavailable.
Running `report_qor -step place` first reconstructs the global-routing
estimate, after which `report_congestion -step place` succeeds.
`report_congestion -step route` remains unavailable because this database
predates detailed routing. The running process has not exported its live
conflicting routes.

The reconstructed estimate differs from the original in-session placement
estimate and must not be substituted for live routing state. It identifies
candidate inspection regions, not the actual remaining 744 conflicts.

| Estimated window | Direction | Average congestion | Level | Same-coordinate SLICE-cell sample |
| --- | --- | ---: | ---: | --- |
| x9..12, y25..40 | East | 81% | 3 | 285 CNN core, 60 DDR, 24 other CNN system, 16 shared DDR bridge, 11 target detector |
| x18..20, y54..55 | East | 90% | 1 | 35 target frame bridge, 10 latency diagnostics, 1 HDMI mixer |
| x17..18, y46..55 | West | 81% | 2 | 66 target frame bridge, 33 HDMI mixer, 19 MC interface, 17 latency diagnostics, 11 other |
| x18, y45..62 | West | 81% | 2 | 54 latency diagnostics, 40 target frame bridge, 34 other |
| x13..15, y34..41 | East | 80% | 2 | 42 CNN core, 36 target detector, 32 other CNN system, 20 shared DDR bridge, 4 DDR |

The listed windows have 100% average LUT utilization in the estimator.
Module counts come from `report_cells -grid` at the same numeric coordinates.
Exact equivalence between the estimator grid and physical cell grid remains
unverified; window samples can overlap and do not count route crossings.
These observations do not establish an AWB-only or CNN-only root cause.

Evidence and repeatable query script:

- `build/ae_awb_routing/inspect_congestion.tcl`
- `build/ae_awb_routing/congestion_windows_console.log`
- `build/ae_awb_routing/congestion_diagnosis/reconstructed_placement.qor`

## Routability Retry

`CongestionHigh` selected for placement did not set routing effort high:
the original run's committed route effort was `normal`.
The build driver now accepts optional `-RouteEffort normal|high|routability`,
applies it before the route-parameter commit even when resuming placement,
and records the override in the release manifest. Leaving it unspecified
preserves the strategy's existing effort setting.

On a route error, the driver attempts to save `failed_route.db`, report
route congestion and routing DRC, then propagates the original failure.
These diagnostics are best effort: the router may already have discarded
some working data. Diagnostic failure cannot convert a failed build into
success or skip the remaining diagnostic commands.

An independent retry started at 15:10:33 local time (driver PID 46856,
TD PID 17308), using the source-matched placed snapshot from the still-running
candidate. The original process was not interrupted.

- Retry snapshot: `C:/Users/1/AppData/Local/Temp/anlogic_image_quality_0bfbf708fb3b467d98f554d30f3d9354`
- Driver-reported source identity: `src-699545ff2de6`
- Driver log: `build/ae_awb_routability/driver_stdout.log`
- Launch script: `build/ae_awb_routing/run_routability.ps1`
- Candidate reports: `build/ae_awb_routability/release`
- Candidate bitstreams: `build/ae_awb_routability/candidate_bit`

Startup confirms committed effort `routability`, `Routing in high effort:
true`, source-manifest equality, the three AE/AWB hold endpoints, and
36 camera / 18 display effective FIFO CDC paths. Acceptance still requires
completed routing, zero open nets, DRC, both-corner final setup/hold timing,
CDC checks and the existing resource budgets. No completed retry or new
validated bitstream is claimed.

Validation: PowerShell syntax and project static checks passed. Eight
generated-Tcl control-flow cases passed in TD's interpreter, covering normal
and placement-resume builds, default and routability effort, success, route
failure and an injected diagnostic failure. These are driver checks, not
evidence of physical convergence.
