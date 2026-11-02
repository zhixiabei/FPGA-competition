# AE/AWB Repair Validation - 2026-11-02

Status: functional regressions passed; final routed implementation pending.
This report covers the current repair, not the rejected histogram-disabled
experiment in `ae_awb_fix_validation_20261102.md`.

## Scope and Symptoms

The reported symptom is cyan white balance, including a white sheet, with a
weak apparent exposure response. The accepted budget allows a small resource
increase, provided placement/routing completes and final setup/hold timing
passes. The histogram must remain enabled.

The current synthesis input identity is `src-08947f93c06a`. Colour detection,
fruit inference, model weights, Gamma placement, sensor register tables, clock
periods and mailbox payload timing bounds are unchanged. The user's existing
project/document edits are preserved.

## Implemented Behaviour

- AE keeps AWB frozen during sensor programming, settling and initial
  convergence. A complete accepted window releases AWB only when the sensor
  setting needs no change. Reaching an exposure/gain limit also permits release.
- Strong changes use a two-frame statistics window only if both accepted frames
  are extreme in the same direction. Mixed and near-target scenes retain the
  six-frame window and the existing exposure/gain steps. Three settling frames,
  target 96..120, exposure 4..1991 and gain 16..176 remain unchanged.
- The 32-bin RAW histogram remains enabled. Its P95 supplies the existing
  bounded highlight bias, at most 16 meter codes, to the AE score.
- AWB always respects AE hold, including the compatibility mode. Hold cancels
  in-progress/pending updates and rejects affected partial frames.
- Production AWB enables spatial coverage, two-frame candidate confirmation,
  bounded tracking, reacquisition and gain deadband.
- The old neutral gate excluded samples with R below half G. The optional red
  recovery branch admits them only with usable red signal (R >= 20 and
  R >= floor(G/4)), close G/B agreement (difference <= floor(G/8)), and an
  unclipped maximum channel of 40..220. Production red capture allows up to
  1024/256 gain; actual gain comes from measured G/R, not a fixed red boost.
- The pixel correction multiplier path, early SOF convention and 54-clock
  data/valid/last delay remain unchanged.
- Only the asynchronous AE-hold source to the first synchronizer stage is
  false-pathed. The second stage and AWB fanout remain normally timed.

## Functional Evidence

Logs are retained under `build/ae_awb_repair/verification`.

| Check | Result / coverage |
| --- | --- |
| Static project/source/interface checks | Pass; exact reviewed substitutions only |
| AE controller | Pass; 1007 checks, 71 requests |
| Short exposure and gain boundaries | Pass; 58 short-exposure + 32 gain cases |
| Accumulator bounds | Pass; averaging 1/6/16, settling 0/3/255 |
| Fixed-count equivalence | Pass; 6 configurations, 24000 frames |
| Two-frame fast window | Pass; 58 checks, 4 configurations |
| AE highlight score | Pass; 258 checks, 256 windows |
| AE production light loop | Pass; 4554 frames, 177 requests/commits, no known nonconvergence |
| AE mean-only reference loop | Pass; 4863 frames, 173 requests/commits |
| RAW statistics and CDC | Pass; 28800 samples at 720p, 301 CDC captures |
| Histogram and histogram CDC | Pass; 8/16/32 bins, sparse/dense/720p/count bounds, malformed parameter rejection |
| AWB confidence/cyan recovery | Pass; 201 frames, 199 checks, 412164 pixels, two additional 720p frames |
| AWB compatibility and hold | Pass; 104 frames, 28 hold boundary checks, exact 54-clock delay |
| ISP production mode | Pass; three 720p frames, 8294400 bytes |
| ISP all modes with hold release and diagnostics | Pass; 10 modes, 30 full 720p frames, 480 diagnostic packets |
| Video FIFO through RAW input | Pass; 6512640 written bytes, 3686400 read pixels, no underflow/overflow or pixel errors |
| SC520 SCL/SDA configuration | Pass; exposure/gain packing, grouped writes, NACK/retry/recovery |

The cyan case supplies RGB(35,100,100). Its target gains are R=731/256 and
B=256/256; after 48 update frames, corrected channels are approximately
99..100. RGB(12,100,100) and RGB(35,100,150) remain rejected. Warm/cool
reacquisition, clipped/dark/strongly coloured scenes, partial frames, line
errors, hold during division and pending commit are also exercised.

Two test setup assumptions were corrected: the cyan capture case now resets
after the deliberately truncated clipping frame; the ISP motion scene expects
confirmation after two clean grey frames, while the colour scene has only one
eligible frame. Neither correction changes production RTL. The ISP reference
also retains the separately established detector observation latency of 11
testbench edges and a background outside the unchanged pale-red threshold.

## Physical Acceptance

Reference release: `build/release`, `src-e5592e27b168`, PH1P35MDG324 speed 3,
Tang Dynasty 6.2.168116. Current run uses `CongestionHigh`, placement seed 1.
The project file's existing GUI strategy is preserved; reproduce the checked
implementation with the explicit CLI strategy below.

| Metric | Original release | Current repair |
| --- | ---: | ---: |
| Slice | 20123 | Pending |
| Physical LUT6 | 19843 | Pending |
| Registers | 20188 | Pending |
| ERAM | 104 / 108 | Pending |
| DSP | 39 / 40 | Pending |
| Final QoR wire length | 9918448 | Pending |
| Setup WNS | +0.100 ns | Pending |
| Hold WNS | +0.020 ns | Pending |
| Setup / hold TNS | 0 / 0 | Pending |
| Setup / hold violating endpoints | 0 / 0 | Pending |
| Open routed nets | 0 | Pending |

Resource ceilings selected before routing: Slice 20600, LUT6 20400,
registers 20700, ERAM 104, DSP 39. Wire length and placement congestion are
reported as measurements, not required to be no greater than the reference.
Final routed STA at both slow and fast corners, zero failing endpoints, no
open nets and effective CDC constraints are required for acceptance. No clock
relaxation or broad asynchronous clock groups are introduced.

Build snapshot:
`C:/Users/1/AppData/Local/Temp/anlogic_image_quality_26dee702c23143e59215378515a4db87`.

A read-only whole-design placement/fanout inspection is recorded in
`docs/ae_awb_routing_diagnosis_20261102.md`. It preserves the running route
and proposes targeted replication and AWB arithmetic staging for later
evaluation. The inspection does not change this build's RTL or establish
final routing/timing acceptance.

## Reproduction

```powershell
./sim/run_auto_exposure.ps1
./sim/run_awb_confidence.ps1
./sim/run_awb_frame_adaptation.ps1
./sim/run_ae_histogram.ps1
./sim/run_isp_lighting_integration.ps1
./sim/run_isp_lighting_integration.ps1 -AllModes -HoldRelease -Diagnostics
./sim/run_video_fifo_frame_integrity.ps1 -RawSource
./sim/run_sc520.cmd --no-pause
python verification/check_merge_readiness.py
./verification/run_image_quality_build.ps1 -PhysicalStrategy CongestionHigh -PlaceSeed 1 -GenerateBit -OutputDirectory build/ae_awb_repair/release -ProgrammingDirectory build/ae_awb_repair/candidate_bit -ResourceLimits @{slice=20600;lut6=20400;reg=20700;eram=104;dsp=39}
./verification/compare_ae_awb_physical.ps1 -CandidateDirectory build/ae_awb_repair/release -ResourceLimits @{slice=20600;lut6=20400;reg=20700;eram=104;dsp=39} -OutputPath build/ae_awb_repair/physical_comparison.json
```

## Limits of the Evidence

There is no new sensor RAW capture or on-board white-sheet measurement in this
run. The new recovery logic addresses a demonstrated sample-rejection dead
zone; it does not establish camera-specific colour calibration. A broad cyan
surface can resemble a cyan illuminant to this statistics-based method.
Exposure light-loop simulation uses the real register lookup/packing but a
simplified illumination and sensor-application model. The separate SCL/SDA
test exercises the real configuration controller and I2C engine.

Timing acceptance applies to the recorded routed build and existing constraint
coverage, not every future seed, strategy or RTL edit. Existing vendor/IP
warnings are not represented as absent. No board programming is performed.
