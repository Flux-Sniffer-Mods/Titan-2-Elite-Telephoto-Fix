# Legacy / superseded

These scripts belong to approaches that were tried and set aside. They are **not**
part of the working solution and are kept only for reference and study. The full
story of why each was abandoned is in the main
[README, "How it works, in depth"](../../README.md#how-it-works-in-depth-the-investigation).

None of these are needed to install or use the telephoto fix. Do not run them
expecting them to work — they document paths that this device's firmware and HAL
ultimately blocked.

## The permission route (Phase 1 — does not open the gate)

An attempt to give Google Camera the privileged `SYSTEM_CAMERA` permission by
rewriting its manifest and installing it as a system app. The camera service
checks the platform *signature*, not the privileged flag, so this reports the
permission as granted yet still cannot open the hidden cameras.

- `axml_add_perm.py` — insert a `<uses-permission>` for `SYSTEM_CAMERA` into an
  app's binary AndroidManifest.xml without decompiling it.
- `axml_verify.py` — verify that the permission was correctly inserted.
- `gcam-titan2-build.sh` — end-to-end: patch the manifest, sign, and install the
  GCam port as a privileged app with an allowlist entry.
- `patch-any-apk.sh` — the generic version of the manifest-patch-and-install flow
  for any APK.

The manifest-editing technique itself is reusable; the permission it grants simply
does not satisfy this device's native check.

## The lens-config route (superseded by the TeleZoom hooks)

An attempt to make GCam expose the telephoto through its own configuration and
aux-button/lens mapping, rather than by hooking it.

- `apply-config.sh`, `gcam_config_fixed.xml` — install a GCam config that maps an
  aux button to the tele and requests a no-RAW YUV path. GCam's photo pipeline is
  RAW-bound regardless of config, so this never produced tele stills in the main
  photo UI.
- `configure-lenses.sh`, `lenses.tsv` — describe/assign the per-lens mapping the
  port's camera array uses.
- `patch-camera-array.sh` — patch the port's internal camera-array so its aux
  buttons index the hidden cameras.

## The cameraserver photo-cave (Phase 5 — built, verified, reverted)

- `cameraserver-patch.sh` — an early cameraserver patcher that also carried the
  "photo cave" (injecting the missing `postRawSensitivityBoostRange` property into
  camera 2). The injection worked mechanically but did not help: the vendor HAL
  blocks telephoto stills below the level any property injection can reach, so the
  cave was reverted. The current, unlock-only patcher is `reject-bypass.sh` in the
  repo root.

## Still useful

The diagnostic scripts that remain relevant were kept out of `legacy/` — see
`tools/cameraserver-recon.sh` (re-derive patch offsets after a firmware update),
`tools/camera-array.sh`, and `tools/collect-diag.sh`.
