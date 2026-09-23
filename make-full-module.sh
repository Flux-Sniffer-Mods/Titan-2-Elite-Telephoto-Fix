#!/data/data/com.termux/files/usr/bin/bash
# make-full-module.sh — build the full flash-and-done Magisk module from source.
#
# Given a CLEAN (unpatched) GCam port APK, this:
#   1. builds the TeleZoom app (TeleZoom/build-on-device.sh),
#   2. bakes TeleZoom into your clean GCam with LSPatch,
#   3. bundles both into titan2-telephoto-FULL.zip.
#
# The resulting module, on first boot, applies the cameraserver unlock, installs
# the TeleZoom app, and installs the patched GCam. Flashing it is the whole install.
#
# Build tools live in Termux (a Magisk module can't compile), so this is a
# one-time "build here, then flash the zip" step.
#
# Usage:
#   ./make-full-module.sh /path/to/clean-gcam.apk [out.zip]
#
# Env (all optional — otherwise fetched/cached automatically):
#   ANDROID_JAR=   path to an android.jar   (see tools/cache-android-jar.sh)
#   LSPATCH_JAR=   path to the LSPatch jar  (else downloaded to ~/.telezoom-cache)
#   XPOSED_JAR=    path to xposed api-82 jar (else the bundled stubs are used)
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
CLEAN="${1:?path to a CLEAN (unpatched) GCam port APK}"
OUT="${2:-$here/titan2-telephoto-FULL.zip}"
CACHE="$HOME/.telezoom-cache"; mkdir -p "$CACHE"

[ -f "$CLEAN" ] || { echo "no such file: $CLEAN"; exit 1; }
if unzip -l "$CLEAN" 2>/dev/null | grep -q "lspatch/origin"; then
  echo "ERROR: '$CLEAN' is already LSPatched. Pass a CLEAN, unmodified GCam APK."; exit 1
fi

# --- android.jar ---
AJ="${ANDROID_JAR:-$CACHE/android.jar}"
[ -f "$AJ" ] || AJ="$(find "$here/TeleZoom" "$HOME" -maxdepth 6 -name android.jar 2>/dev/null | head -1)"
[ -n "${AJ:-}" ] && [ -f "$AJ" ] || { echo "no android.jar found. Run: bash tools/cache-android-jar.sh  (or set ANDROID_JAR=)"; exit 1; }

# --- build TeleZoom ---
echo "==> Building TeleZoom app"
( cd "$here/TeleZoom" && rm -rf build TeleZoom-signed.apk \
  && ANDROID_JAR="$AJ" XPOSED_JAR="${XPOSED_JAR:-$HOME/xposed-api-82.jar}" bash build-on-device.sh )
TZ="$here/TeleZoom/TeleZoom-signed.apk"
[ -f "$TZ" ] || { echo "TeleZoom build produced no APK"; exit 1; }

# --- LSPatch jar ---
LSP="${LSPATCH_JAR:-$CACHE/lspatch.jar}"
if [ ! -f "$LSP" ]; then
  echo "==> Fetching LSPatch"
  URL="$(curl -fsSL https://api.github.com/repos/JingMatrix/LSPatch/releases/latest 2>/dev/null | grep -o 'https://[^"]*\.jar' | head -1)"
  [ -z "$URL" ] && URL="$(curl -fsSL https://api.github.com/repos/LSPosed/LSPatch/releases/latest 2>/dev/null | grep -o 'https://[^"]*\.jar' | head -1)"
  [ -n "$URL" ] || { echo "could not find an LSPatch release jar (set LSPATCH_JAR=)"; exit 1; }
  curl -fsSL "$URL" -o "$LSP"
fi

# --- LSPatch the clean GCam ---
echo "==> Baking TeleZoom into GCam with LSPatch"
rm -rf "$here/.lspatched"
java -jar "$LSP" -f -l 2 -m "$TZ" -o "$here/.lspatched" "$CLEAN"
GC="$(ls "$here"/.lspatched/*.apk 2>/dev/null | head -1)"
[ -n "$GC" ] || { echo "LSPatch produced no APK"; exit 1; }

pkg="$(aapt dump badging "$GC" 2>/dev/null | sed -n "s/.*package: name='\([^']*\)'.*/\1/p")"
[ -n "$pkg" ] || pkg=com.google.android.GoogleCameraEngR18F1

# --- package the module ---
echo "==> Packaging the module"
work="$(mktemp -d)"; trap 'rm -rf "$work" "$here/.lspatched"' EXIT
cp -a "$here/magisk-module/." "$work/"
cp "$TZ" "$work/telezoom.apk"
cp "$GC" "$work/gcam-patched.apk"
printf '%s' "$pkg" > "$work/gcam-pkg"
( cd "$work" && rm -f "$OUT" && zip -qr -X "$OUT" . )

echo
echo "Built: $OUT"
echo "  GCam package: $pkg"
echo "  Flash it in Magisk and reboot. First boot does the whole install."
