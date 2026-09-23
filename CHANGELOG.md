# Changelog

## v1.1
- **Play Protect fix**: the cameraserver unlock no longer leaves a standing SELinux
  rule. The `allow su cameraserver ptrace` rule is now added only for the moment the
  patch is written and removed immediately afterward (matching `deny`), so the live
  policy is unchanged and Google Play Protect no longer flags the device. On setups
  where root can already ptrace across domains, no rule is added at all.
- Single full Magisk module is the sole release artifact; `make-full-module.sh` is
  the one build entry point.
- Added `tools/legacy/` with the superseded approaches (permission route,
  lens-config route, photo-cave) documented for reference.
- Install-first README with the complete investigation writeup folded in.

## v1.0
- Initial release: cameraserver system-camera unlock (four-site RAM patch),
  TeleZoom hooks for telephoto video, TeleShot + TELE button for telephoto stills,
  bundled as a flash-and-done Magisk module.
