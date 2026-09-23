#!/data/data/com.termux/files/usr/bin/bash
#
# collect-diag.sh
#
# Captures a complete picture of one GCam launch-and-crash, from a cold
# start, entirely as root. Produces a single file to hand over.
#
#   Repo: https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix
#
# Everything runs under su, including the log capture itself, because a
# redirect written by the Termux shell cannot reach root-only paths and a
# logcat started after the app has already crashed captures nothing.
#
# Usage:
#   ./collect-diag.sh              capture a launch, wait for you to tap
#   ./collect-diag.sh -o FILE      write somewhere other than the default

set -u

PKG="com.google.android.GoogleCameraEngR18F1"
DATADIR="/data/data/$PKG"
PREFS="$DATADIR/shared_prefs/${PKG}_preferences.xml"
MODDIR="/data/adb/modules/gcam_priv"
APPDIR="$MODDIR/system/priv-app/GoogleCameraEng"
LAUNCH="$PKG/com.android.camera.CameraLauncher"

OUT="$HOME/gcam-diag-$(date +%Y%m%d-%H%M%S).log"
RAW="$HOME/.cache/gcam-diag-raw.log"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$BLD" "$*" "$RST"; }
ok()   { printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s[!]%s  %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*" >&2; exit 1; }
as_root() { su -c "$*"; }

# section HEADER COMMAND - run a root command, append titled output
section() {
  {
    printf '\n\n===============================================================\n'
    printf '== %s\n' "$1"
    printf '===============================================================\n'
  } >> "$OUT"
  as_root "$2" >> "$OUT" 2>&1 || printf '(command failed)\n' >> "$OUT"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift; OUT="${1:?-o needs a path}" ;;
    *)  die "Usage: $0 [-o FILE]" ;;
  esac
  shift
done

su -c 'id -u' >/dev/null 2>&1 || die "No root. Grant Termux root access in Magisk."
mkdir -p "$(dirname "$RAW")"
: > "$OUT"

step "Environment"
{
  printf '== GCam diagnostic ==\n'
  printf 'date:     %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  printf 'package:  %s\n' "$PKG"
  printf 'android:  %s (sdk %s)\n' \
    "$(getprop ro.build.version.release)" "$(getprop ro.build.version.sdk)"
  printf 'device:   %s %s\n' \
    "$(getprop ro.product.manufacturer)" "$(getprop ro.product.model)"
  printf 'build:    %s\n' "$(getprop ro.build.fingerprint)"
} >> "$OUT"
ok "recorded"

step "Static state"
section "PACKAGE FLAGS AND PERMISSIONS" \
  "dumpsys package $PKG | grep -E 'codePath|flags=|privateFlags=|versionName|SYSTEM_CAMERA|CAMERA:|firstInstallTime'"
section "MODULE CONTENTS" \
  "ls -la '$APPDIR' '$APPDIR/lib/arm64' 2>&1 | head -40"
section "MODULE FILES" \
  "cat '$MODDIR/module.prop' '$MODDIR/system.prop' '$MODDIR/system/etc/permissions/privapp-permissions-gcam.xml' 2>&1"
section "CAMERA HAL INVENTORY" \
  "dumpsys media.camera | grep -E 'Number of camera|static information|^ +Facing|supportedHardwareLevel|availableCapabilities' | head -60"
section "CAMERA PROPS" \
  "getprop | grep -iE 'camera' | head -40"
section "CURRENT PREFERENCES" \
  "cat '$PREFS'"
ok "collected"

step "Cold start"
as_root "am force-stop $PKG"
as_root "logcat -c" 2>/dev/null
as_root "logcat -b crash -c" 2>/dev/null
ok "app stopped, log buffers cleared"

# The capture runs as root and writes to a root-owned file. Starting it
# BEFORE the launch is the point - a log read after the crash has already
# happened will have lost the interesting part.
as_root "logcat -b main,crash,system -v threadtime > '$RAW' 2>&1 &"
sleep 1
ok "logcat capturing to $RAW"

as_root "am start -n $LAUNCH" >/dev/null 2>&1
ok "launched $LAUNCH"

printf '\n%s---------------------------------------------------------%s\n' "$BLD" "$RST"
printf '  %sNow, in GCam:%s\n' "$BLD" "$RST"
printf '    1. let the viewfinder finish loading\n'
printf '    2. tap the aux / lens button so it crashes\n'
printf '    3. come back here and press ENTER\n'
printf '%s---------------------------------------------------------%s\n\n' "$BLD" "$RST"
printf '  Press ENTER once it has crashed... '
read -r _

sleep 2
as_root "pkill -f 'logcat -b main,crash,system'" 2>/dev/null
sleep 1
ok "capture stopped"

step "Extracting"
section "FATAL EXCEPTION" \
  "grep -A45 -m2 'FATAL EXCEPTION' '$RAW'"
section "PORT CAMERA ARRAY (GotArray = the list the port built)" \
  "grep -E 'GotArray|CameraManager2' '$RAW' | head -40"
section "FRAMEWORK CAMERA VISIBILITY" \
  "grep -E 'CameraManagerGlobal|CameraService' '$RAW' | grep -vE 'torch' | head -60"
section "PERMISSION DENIALS" \
  "grep -iE 'permission denial|not permitted|SecurityException|system camera' '$RAW' | head -30"
section "CAMERA OPEN / CONFIGURE" \
  "grep -iE 'openCamera|connectDevice|createCaptureSession|configureStreams|CameraDeviceClient' '$RAW' | head -40"
section "GCAM PROCESS LOG (last 200 lines)" \
  "grep -E '$PKG|GoogleCamera|eCameraEngR18F1' '$RAW' | tail -200"

as_root "chown $(id -u):$(id -u) '$OUT'" 2>/dev/null
as_root "rm -f '$RAW'" 2>/dev/null

step "Done"
if grep -q "FATAL EXCEPTION" "$OUT"; then
  ok "a fatal exception was captured"
  printf '\n  %s\n' "$(grep -m1 -A3 'FATAL EXCEPTION' "$OUT" | tail -2 | head -1)"
else
  warn "no fatal exception in the capture - did it actually crash?"
fi
printf '\n  Output: %s  (%s)\n\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
printf '  Send that file.\n\n'
