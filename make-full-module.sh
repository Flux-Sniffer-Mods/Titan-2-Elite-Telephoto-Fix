#!/data/data/com.termux/files/usr/bin/bash
# make-full-module.sh — package a FLASH-AND-DONE Magisk module from artifacts you
# already built, so future installs are just "flash this zip":
#   - reapplies the cameraserver unlock every boot
#   - installs the TeleZoom app
#   - installs the patched GCam once
#
# Build must happen first (JDK/aapt/d8/LSPatch live in Termux, not in a module):
#   1. TeleZoom/build-on-device.sh        -> TeleZoom-signed.apk
#   2. LSPatch a CLEAN GCam with that apk -> the *-lspatched.apk
# Then run this to bundle both.
#
# Usage:
#   ./make-full-module.sh <TeleZoom-signed.apk> <gcam-lspatched.apk> [out.zip]
set -eu
TZ="${1:?path to TeleZoom-signed.apk}"
GC="${2:?path to the LSPatched gcam apk}"
OUT="${3:-titan2-telephoto-FULL.zip}"
here="$(cd "$(dirname "$0")" && pwd)"
[ -f "$TZ" ] || { echo "no such file: $TZ"; exit 1; }
[ -f "$GC" ] || { echo "no such file: $GC"; exit 1; }

# sanity: GC must be an LSPatched apk (contains the embedded origin)
unzip -l "$GC" 2>/dev/null | grep -q "lspatch/origin" || { echo "WARNING: $GC does not look LSPatched (no lspatch/origin)"; }

pkg="$(aapt dump badging "$GC" 2>/dev/null | sed -n "s/.*package: name='\([^']*\)'.*/\1/p")"
[ -n "$pkg" ] || pkg=com.google.android.GoogleCameraEngR18F1

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cp -a "$here/magisk-module/." "$work/"
cp "$TZ" "$work/telezoom.apk"
cp "$GC" "$work/gcam-patched.apk"
printf '%s' "$pkg" > "$work/gcam-pkg"
# bump the module name so it's clearly the full build
sed -i 's/^name=.*/name=Titan 2 Elite Telephoto (full: unlock + app + patched GCam)/' "$work/module.prop"

( cd "$work" && rm -f "$OUT" && zip -qr -X "$here/$OUT" . )
echo "built: $here/$OUT"
echo "  package: $pkg"
echo "  flash it in Magisk. First boot: unlock + installs the app + installs GCam."
