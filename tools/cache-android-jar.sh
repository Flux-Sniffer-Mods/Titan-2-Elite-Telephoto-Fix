#!/data/data/com.termux/files/usr/bin/bash
# cache-android-jar.sh — find an android.jar on this device and copy it to a
# stable, wipe-proof location so builds never need to re-download it.
#
#   Cache: ~/.telezoom-cache/android.jar
#   Then:  export ANDROID_JAR=~/.telezoom-cache/android.jar   (build-on-device.sh
#          / install.sh / make-full-module.sh all honour ANDROID_JAR)
#
# Usage:
#   ./cache-android-jar.sh                 # search + cache
#   ./cache-android-jar.sh /path/to/android.jar   # cache a specific file
set -u
CACHE="$HOME/.telezoom-cache"
DST="$CACHE/android.jar"
mkdir -p "$CACHE"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

ok(){ printf '  [ok] %s\n' "$*"; }
warn(){ printf '  [!]  %s\n' "$*"; }

# already cached?
if [ -f "$DST" ] && [ "${1:-}" = "" ]; then
  ok "already cached: $DST ($(wc -c <"$DST") bytes)"
  echo "  export ANDROID_JAR=$DST"
  exit 0
fi

src="${1:-}"
if [ -n "$src" ]; then
  [ -f "$src" ] || { warn "no such file: $src"; exit 1; }
else
  echo "Searching for android.jar on device..."
  for c in "$HOME/.telezoom-build/android.jar" \
           $HOME/android-sdk/platforms/android-*/android.jar \
           $HOME/Android/Sdk/platforms/android-*/android.jar \
           "$PREFIX/share/aapt/android.jar"; do
    [ -f "$c" ] && { src="$c"; break; }
  done
  [ -z "$src" ] && src="$(find "$HOME" "$PREFIX/share" -maxdepth 6 -name android.jar 2>/dev/null | head -1)"
  [ -z "$src" ] && src="$(su -c 'find /sdcard /storage/emulated/0 -maxdepth 6 -name android.jar' 2>/dev/null | head -1)"
fi

if [ -z "$src" ]; then
  warn "no android.jar found on device."
  warn "Grab one from an Android SDK (platforms/android-XX/android.jar) or let"
  warn "install.sh download it once, then re-run this to cache that copy."
  exit 1
fi

# sanity: must be a zip/jar containing android/ classes
if command -v unzip >/dev/null 2>&1 && ! unzip -l "$src" 2>/dev/null | grep -q 'android/'; then
  warn "$src does not look like a valid android.jar (no android/ entries)"; exit 1
fi

cp "$src" "$DST" 2>/dev/null || { su -c "cp '$src' '$DST'"; su -c "chown $(id -u):$(id -g) '$DST'" 2>/dev/null || true; }
[ -f "$DST" ] || { warn "copy failed"; exit 1; }
ok "cached: $src -> $DST ($(wc -c <"$DST") bytes)"
echo
echo "  Use it:  export ANDROID_JAR=$DST"
echo "  (add that line to ~/.bashrc to make every build pick it up automatically)"
