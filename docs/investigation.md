# Investigation

The full technical write-up (how the system-camera lock works, how each layer was
defeated, and the approaches that failed) lives in the main
[README](../README.md#how-it-works-in-depth-the-investigation), alongside the
install instructions.

See **"How it works, in depth (the investigation)"** there. It covers:

- Phase 0: the goal and the shape of the problem
- Phases 1 to 3: removing the system-camera lock (the core fix)
- Phases 4 and 5: the photo crash, and the abandoned "photo cave"
- Phase 6: the re-sign trap
- Phases 7 and 8: reaching the telephoto through zoom on the logical camera, and
  the TeleShot stills route
- Phase 9: shipping without Xposed (LSPatch), and the font-init bug
- Re-deriving offsets after a firmware update
