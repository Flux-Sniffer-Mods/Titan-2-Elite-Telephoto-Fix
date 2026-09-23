# Dependencies

**Installing** the release needs nothing but Magisk: flash the module.

**Building** it yourself (Termux, rooted):
```sh
pkg update && pkg upgrade -y
pkg install -y openjdk-17 aapt d8 apksigner zip unzip curl python git
```
Plus, gathered automatically by the build scripts (or provide your own):
- `android.jar`: reuse one already on the device: `bash tools/cache-android-jar.sh`
  (caches to `~/.telezoom-cache/android.jar`), or set `ANDROID_JAR=`.
- **LSPatch** jar: auto-downloaded to `~/.telezoom-cache/lspatch.jar`, or set `LSPATCH_JAR=`.
- A **clean** GCam port APK to patch (passed to `make-full-module.sh`).

For re-deriving cameraserver offsets on new firmware:
`radare2` + `r2pm -ci r2ghidra`, and `jadx` to read GCam.

`magiskpolicy` ships with Magisk (scripts fall back to `/data/adb/magisk/magiskpolicy`).
