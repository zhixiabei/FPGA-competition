# AE/AWB Routing Relief, 2026-11-02

## Status Update at 17:39

The original candidate is no longer running. Its saved log ends at
phase-one iteration 34 with 812 overused routing resources, with no final
routed timing or accepted bitstream. The log has no final tool failure
message; its outcome is incomplete, not passed. The preceding repair did
explicitly fail with PHY-8080 at 14:47:11. Historical pending/running notes
below describe the earlier observation time.

At the user's request, later CNN/detector/frame-bridge edits were backed up
and the production source was restored to this candidate's 273-entry
manifest. See `docs/ae_awb_restore_comparison_20261102.md` for the restoration
record and comparison against the known routed baseline. No new physical
run was started during restoration.

## Change

Source `src-48fcf269deaa` is an independent candidate derived from the
functionally verified AE/AWB repair `src-08947f93c06a`.

Two AWB changes trade a small amount of register/counter logic for shorter
paths and local address routing:

1. Store the smoothed red/blue gain when a completed ratio is accepted.
   SOF and the first valid pixel select this prepared value. The divider,
   gain limits, rounding, candidate/hold decisions and frame commit schedule
   are preserved. This moves smoothing out of the pixel-multiplier path.
2. Replace the single 64x96 distributed delay RAM with four 64x24 instances.
   Each lane has preserved same-phase read/write counters. The read pointer
   still resets to 13 and the write pointer to zero; RAM READREG remains
   enabled. Pixel/valid/last latency remains 54 clocks and the early user
   marker is unchanged. Total storage remains 6144 bits.

The explicit RTL increase before optimization is 22 gain-register bits and
36 address-register bits. Actual physical cost is measured after placement
and routing. No additional DSP or ERAM is requested. AE, histogram, colour
detection, fruit inference, Gamma selection and timing constraints are
unchanged from the preceding repair.

## Physical Replication Probe

Before the RTL change, isolated copies of the placed DB were used to test
TD `phys_opt -force_replication_on_nets` on the CNN activation sign broadcast
and an AWB read-address bit. Post-place/direct forms, object selection and
lower fanout thresholds did not reduce these targets. The CNN target still
had 384 load pins, and the AWB target 99. These probe results were not used
as release inputs. The original routing process was not interrupted.

Probe evidence: `build/ae_awb_repair/fanout_probe*`.

## Functional Validation

| Check | Result |
| --- | --- |
| AWB confidence, cyan recovery, warm/cool reacquisition | Pass: 201 frames, 199 checks, 412164 pixels, two 720p frames |
| AWB compatibility/frame adaptation | Pass: 104 frames, 27388 pixels, one 720p frame |
| AE hold and SOF/first-pixel boundaries | Pass: 32 checks, 15944 pixels, 54-clock latency |
| ISP all modes, diagnostics and hold release | Pass: 10 modes, 30 720p frames |
| Static project/interface/edit-scope checks | Pass |
| Final routed STA/DRC/resource/CDC checks | Pending |

The hold test adds completion-edge SOF, immediately following SOF, and
completion-edge hold cases. It compares actual output pixels, gain state
and delayed markers, rather than only checking new internal registers.
The production primitive model is used for distributed RAM simulation.
All ten integration modes finished successfully at 13:43 local time.
The physical source manifest matches the workspace, and overlapping
integration RTL hashes match that physical snapshot. Normal, motion,
emboss, cartoon, morphology, inverse Scharr, binary, erosion, dilation and
closing modes each retain pixel packing, frame tags, histogram data and
AE/AWB hold-release behavior.

AWB evidence:

- `build/ae_awb_routing/verification/awb_confidence`
- `build/ae_awb_routing/verification/awb_frame_hold`
- `build/ae_awb_routing/verification/isp_all_modes`
- `C:/Users/1/AppData/Local/Temp/anlogic_awb_frame_e28e66a258424fa6856a7e53cd439489`
- `C:/Users/1/AppData/Local/Temp/anlogic_isp_lighting_e85a0262c22f4b6d8ef8bd7587a228a4`

## Physical Validation

Candidate snapshot:
`C:/Users/1/AppData/Local/Temp/anlogic_image_quality_f90cb49ea6a744d78f10a5b8dc1081fc`.

TD 6.2.168116, PH1P35MDG324 speed 3, CongestionHigh, place seed 1.
Started 2026-11-02 13:24:02 local time. Final result is pending.
The gate netlist confirms all four pairs of preserved address counters.

Placement completed in 328.64 seconds. The independent read-only DB audit
also confirms all 48 address-register bits and 22 prepared-gain bits after
physical optimization. Address bit 3 has 27 loads per bank, compared with
99 loads on the former shared read-address net. Across all six read bits,
each local bank has 25 to 29 loads per bit.

| Placed metric | Previous repair | Routing-relief candidate |
| --- | ---: | ---: |
| Slice | 20368 | 20317 |
| LUT6 | 19966 | 20062 |
| Register | 20230 | 20297 |
| ERAM | 104 | 104 |
| DSP | 39 | 39 |
| Top 1% tile average utilization | 96.42% | 95.55% |
| Tiles over 100% utilization | 7 | 7 |
| Setup WNS | +1.281 ns | +1.438 ns |
| Hold WNS | -0.284 ns | -0.273 ns |

These are placement estimates, including unresolved hold violations. They
do not meet the final routed acceptance criteria by themselves. Physical
packing uses 51 fewer slices despite 96 extra LUTs and 67 extra registers;
the mapped difference need not equal the explicit RTL bit count.

The prepared-gain output path to the pixel DSP is now two logic levels,
4.692 ns data delay, +4.682 ns setup slack, and maximum fanout four.
The former smoothing-to-pixel path was eight levels, 8.032 ns data delay,
+1.342 ns setup slack, and maximum fanout eight. This is a comparison of
corresponding path classes, not identical endpoints. The new preparation
input path itself has +2.001 ns placed setup slack and +0.064 ns hold slack.

Evidence: `build/ae_awb_routing/placement_audit_console.log` and
`build/ae_awb_routing/placement_audit/{placement.area,prepared_gain_outputs.timing,prepared_gain_inputs.timing}`.

Acceptance requires final routed timing at both slow/fast corners, setup and
hold WNS >= 0, TNS = 0, zero failing endpoints, no open nets/DRC failures,
and effective existing CDC constraints. Resource ceilings remain Slice
20600, LUT6 20400, registers 20700, ERAM 104, DSP 39. Candidate output paths
are separate from the prior working release. No board programming occurs.

```powershell
./verification/run_image_quality_build.ps1 -PhysicalStrategy CongestionHigh -PlaceSeed 1 -GenerateBit -OutputDirectory build/ae_awb_routing/release -ProgrammingDirectory build/ae_awb_routing/candidate_bit -ResourceLimits @{slice=20600;lut6=20400;reg=20700;eram=104;dsp=39}
```

Faster convergence and timing closure are objectives under measurement,
not claims established by functional simulation or a synthesized estimate.
