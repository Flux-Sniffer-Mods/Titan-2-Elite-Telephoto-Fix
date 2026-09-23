# Legacy / superseded

These belong to earlier approaches that are **not** part of the working
solution. Kept for reference only.

- `apply-config.sh`, `gcam_config_fixed.xml` — the GCam config route (tele
  button -> cam2, no-RAW YUV path). Superseded: GCam's photo pipeline is
  RAW-bound regardless of config, so this never yielded tele stills in the main
  photo UI. Tele stills now come from the TeleShot intent-capture flow. See
  `the README ("How it works, in depth")`, Parts B and D.

The discovery/diagnostic scripts one level up in `tools/` (`camera-array.sh`,
`cameraserver-recon.sh`, `collect-diag.sh`) are still useful for re-deriving
patch offsets on a new firmware build.
