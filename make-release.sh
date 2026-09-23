#!/data/data/com.termux/files/usr/bin/bash
# make-release.sh — build THE release: a single full Magisk module that, on first
# boot, applies the unlock, installs the TeleZoom app, and installs the patched GCam.
#
# Build order (JDK/aapt/d8/LSPatch are Termux-only, not in a module):
#   1. this script builds TeleZoom-signed.apk
#   2. you provide a CLEAN GCam port APK; this script LSPatches it
#   3. it bundles both into titan2-telephoto-FULL.zip
#
# Usage:
#   ./make-release.sh <clean-gcam.apk>
# Env: ANDROID_JAR=, LSPATCH_JAR= (else it looks in ~/.telezoom-cache and downloads)
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
CLEAN="${1:?path to a CLEAN (unpatched) GCam port APK}"
[ -f "$CLEAN" ] || { echo "no such file: $CLEAN"; exit 1; }
unzip -l "$CLEAN" 2>/dev/null | grep -q "lspatch/origin" && { echo "ERROR: $CLEAN is already LSPatched — pass a CLEAN GCam apk"; exit 1; }
OUT="$here/titan2-telephoto-FULL.zip"
CACHE="$HOME/.telezoom-cache"; mkdir -p "$CACHE"

# android.jar
AJ="${ANDROID_JAR:-$CACHE/android.jar}"
[ -f "$AJ" ] || AJ="$(find "$here/TeleZoom" "$HOME" -maxdepth 6 -name android.jar 2>/dev/null | head -1)"
[ -n "$AJ" ] && [ -f "$AJ" ] || { echo "no android.jar — run tools/cache-android-jar.sh or set ANDROID_JAR="; exit 1; }

echo "==> Building TeleZoom app"
( cd "$here/TeleZoom" && rm -rf build TeleZoom-signed.apk \
  && ANDROID_JAR="$AJ" XPOSED_JAR="${XPOSED_JAR:-$HOME/xposed-api-82.jar}" bash build-on-device.sh )
TZ="$here/TeleZoom/TeleZoom-signed.apk"

# LSPatch
LSP="${LSPATCH_JAR:-$CACHE/lspatch.jar}"
if [ ! -f "$LSP" ]; then
  echo "==> Fetching LSPatch"
  URL="$(curl -fsSL https://api.github.com/repos/JingMatrix/LSPatch/releases/latest 2>/dev/null | grep -o 'https://[^"]*\.jar' | head -1)"
  [ -z "$URL" ] && URL="$(curl -fsSL https://api.github.com/repos/LSPosed/LSPatch/releases/latest 2>/dev/null | grep -o 'https://[^"]*\.jar' | head -1)"
  [ -n "$URL" ] || { echo "no LSPatch jar (set LSPATCH_JAR=)"; exit 1; }
  curl -fsSL "$URL" -o "$LSP"
fi

echo "==> LSPatching GCam"
rm -rf "$here/.lspatched"
java -jar "$LSP" -f -l 2 -m "$TZ" -o "$here/.lspatched" "$CLEAN"
GC="$(ls "$here"/.lspatched/*.apk | head -1)"
[ -n "$GC" ] || { echo "LSPatch produced no apk"; exit 1; }

echo "==> Packaging the full module"
bash "$here/make-full-module.sh" "$TZ" "$GC" "$OUT"
rm -rf "$here/.lspatched"
echo
echo "Release asset: $OUT"
echo "Upload it to a GitHub Release. Flashing it does everything on first boot."
