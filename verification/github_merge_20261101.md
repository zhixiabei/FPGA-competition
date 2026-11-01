# GitHub integration (2026-11-01)

## Source identity and scope

- Repository: `zhixiabei/FPGA-competition`.
- Previous local main: `1513c35`.
- Fetched and fast-forwarded main: `71ce808ec8de4dece7213996dd4ff5e3f295ce74`.
- Incoming changes: 2075 files, primarily training data, model checkpoints,
  RGB background comparison, confirmed-empty label clearing, model CRC and
  confidence table updates, plus verification tools and documentation.
- User selected the new upstream behavior. Production fruit RTL is retained
  exactly as fetched; the local shape contour repair and registered ALU remain.
- No local commit or push was made. Local edits remain in the working tree.

The five existing local files were backed up with a binary Git patch and a
SHA256 manifest in `build/github_merge_20261101/before_merge`. No upstream
change overlapped those files. All five hashes matched after the fast-forward.
The detector remains SHA256
`BAA753ECB4CE425D3AC228C963DCA6F06DCDBC455507EA4D74231C6E7F15D730`.

## Integration adjustments

Both `td_project/anlogic_edge_osd.al` and the incoming voice-optimized project
now use this workspace's project directory instead of the upstream author's
absolute E: drive path. Project source and constraint references are retained.

The existing fruit ROI system test assumed missing texture and confirmed
empty background had identical label retention. That expectation fails with
the new upstream clearing rule. Its existing texture-only checks now supply
foreground explicitly, while two additional cases independently require
immediate empty-scene clearing with and without texture. Reacquisition still
requires confirmation. Snapshot backpressure, shutdown and error checks remain.
The runner exits on simulator break/failure and normal finish.

No production fruit algorithm or model constant was altered during integration.
The canonical-project note now distinguishes this machine's evidence from
the upstream author's historical verification and programming statements.

## Verification

Evidence below is relative to `build/github_merge_20261101/`.

| Check | Result | Evidence |
| --- | --- | --- |
| Existing local modifications | 5 files preserved byte for byte | `before_merge/local_files_sha256.json` |
| Main source, pins, project paths and named interfaces | PASS against new `origin/main`, 2712 tracked files | `verification/check_merge_readiness.py` |
| Incoming voice-optimized project paths and interfaces | PASS, 110 files and 126 instances | `check_project` from the same script |
| RGB128 preprocessing and RGB555 background reference | PASS, 3 cases, 49152 normalized samples per case | `roi_preprocess` |
| Fruit ROI system including confirmed-empty clearing | PASS, 156 checks, 2 explicit empty cases | `roi_system` |
| Shape contour smoke regression | PASS, 22 frames, 8 cases, 20 checks | `shape_probe` |
| Registered shape ALU versus original formula | PASS, 1188 operations | `shape_probe` |
| Git whitespace/conflict checks | PASS | `git diff --check`, no unmerged entries |

All three final simulation runs completed with zero simulator errors and
warnings. `roi_system_before_adaptation` retains the expected failure of the
old test's flat/empty assumption; it is not a passing result.

## Model dependency and remaining limits

The new RTL requires model CRC32 `3a37bea7`. The upstream project note refers
to `build/fruit/weights`, but that ignored directory is absent here and the
tracked upstream tree contains no matching `model.bin` or `model.hex` export.
Floating-point training checkpoints do not substitute for that exported bundle.

The existing local `build/flash_model/model.hex` decodes to 170752 bytes,
CRC32 `bbd4adef`, SHA256
`b890089e104caf255f574c740732ab65b7eb14d369fdd7a6d31c2303eccc9db9`.
The saved programming record also reports `bbd4adef`. This is historical local
evidence, not a fresh read of U30. The boot module checks the model CRC and
will not assert model_ready for mismatched content. Keep the new config and
obtain its matching exported weights before deployment unless the board is
independently confirmed to already contain that exact model.

No training, model export, synthesis, placement/routing, bit generation or
programming was performed. The prior physical congestion remains unverified.
The full shape/vendor/720p suites were not repeated because all shape RTL and
dependencies were unchanged by this merge; the focused shape test was rerun.
