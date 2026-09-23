# Third-party components

Everything in this repository is licensed under the [MIT License](LICENSE).
This file records the third-party pieces the project works with, and makes clear
which of them are not redistributed here.

## What is not redistributed here

No third-party binaries are stored in this repository. The build scripts fetch these
at build time, onto your own device:

- **LSPatch** (https://github.com/LSPosed/LSPatch), downloaded to
  `~/.telezoom-cache/lspatch.jar`, or supplied with `LSPATCH_JAR=`
- **android.jar**, taken from an SDK already present on the device by
  `tools/cache-android-jar.sh`, or supplied with `ANDROID_JAR=`
- **Google Camera (GCam)**, supplied by you. The scripts patch a copy on your device;
  no GCam build is stored here
- **magiskpolicy**, which ships with Magisk

## What the release module bundles

The flashable module attached to each
[release](https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix/releases/latest)
is a convenience build. Besides this project's own code it contains a patched build of
the third-party Google Camera port, with TeleZoom embedded by LSPatch. The GCam port
is the work of its original authors; it is bundled so the module installs in one step,
and is not part of this repository's source.

## `TeleZoom/xposed-stubs/`

These are minimal stand-in declarations of the Xposed API (empty method bodies),
written for this project so the module can be compiled on-device without pulling in
the Xposed API jar. They are not the Xposed implementation and contain no upstream
code. The real framework is:

- Xposed API: https://github.com/rovo89/XposedBridge
- LSPosed: https://github.com/LSPosed/LSPosed

At run time the module is loaded by LSPosed, which provides the real implementation.

## Camera firmware and offsets

The cameraserver work in `tools/` inspects vendor binaries that are already present
on your own device. No vendor or firmware code is included in this repository.
