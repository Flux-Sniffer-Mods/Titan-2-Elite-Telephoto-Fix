# Investigation

The full technical write-up — how the system-camera lock works, how each layer
was defeated, and the approaches that failed — now lives in the main
[README](../README.md#how-it-works-in-depth-the-investigation) so that it sits
alongside the install instructions in one place.

See **"How it works, in depth (the investigation)"** there. It covers:

- Part A — removing the system-camera lock (the core fix)
- Part B — the abandoned "photo cave" and why it failed
- Part C — reaching the telephoto via zoom on the logical camera
- Part D — why GCam's main Photo mode cannot use the telephoto
- Part E — shipping without Xposed (LSPatch), and the font-init bug
- Re-deriving offsets after a firmware update
