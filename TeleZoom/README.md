# TeleZoom

The in-GCam half of the Titan 2 Elite telephoto project. An Xposed/LSPosed
module (also bakeable into GCam with LSPatch) plus a small companion app.

## What it does

Inside GCam (`com.google.android.GoogleCameraEngR18F1`):

- **Redirect** `openCamera("0")` → `"3"`, the logical multi-camera that owns the
  SAT lens switch. (Front camera untouched.)
- **Zoom-ratio translation** — turn GCam's `SCALER_CROP_REGION` crop zoom into
  `CONTROL_ZOOM_RATIO` on cam 3, so the MediaTek SAT HAL switches to the 6.8 mm
  tele past its optical crossover. This is what makes **tele video** work.
- **TELE button** — a floating button on GCam's main screen that launches the
  TeleShot flow for a **tele still**.
- **Auto-tele** — when GCam is launched by TeleShot, the zoom is scaled so it
  opens already framed on the tele.
- **FontsContract fix** — only relevant to LSPatch builds: seeds the
  `FontsContract` context that LSPatch's late module load otherwise leaves null
  (which crashed the fonts thread → black photo preview). A no-op under LSPosed.

Companion app (`com.fluxsniffer.telezoom`, **no launcher icon** — driven by the
TELE button):

- **TeleShot** — launches GCam's `ACTION_IMAGE_CAPTURE` (its only no-RAW still
  path, so the tele can serve it) with its own content provider as the output
  target, then copies the processed JPEG into `DCIM/Camera` and stamps
  `DateTimeOriginal`.
- **ShotProvider** — the content provider GCam writes the capture into (GCam
  refuses `file://` and pending-MediaStore targets).

See `../the README ("How it works, in depth")` Parts C–E for the full reasoning.

## Build (on device, in Termux)

```sh
export ANDROID_JAR="$(find $PWD -name android.jar | head -1)"
export XPOSED_JAR=~/xposed-api-82.jar        # optional; bundled stubs used if absent
bash build-on-device.sh
```

Produces `TeleZoom-signed.apk`. Install it, then either enable it in LSPosed
(scope: GCam) **or** bake it into GCam with LSPatch — see the top-level
`README.md`.

## Tunables (top of `ZoomHook.java`)

| Flag | Meaning |
|------|---------|
| `REDIRECT` / `REDIRECT_TO` | open cam 3 instead of cam 0 |
| `RATIO_MODE` | crop→zoom-ratio translation (the tele-switch mechanism) |
| `TELE_BUTTON` | show the in-GCam TELE button |
| `TELESHOT_BASE_RATIO` | zoom scale applied in TeleShot mode (UI 1× = tele) |
| `TELESHOT_AUTO_DONE` | auto-press GCam's Done on the review screen (default off) |
| `HIDE_RAW` / `PHOTO_NO_RAW` | abandoned photo-mode experiments (default off) |
| `DIAG` | verbose logging |
