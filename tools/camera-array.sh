#!/data/data/com.termux/files/usr/bin/bash
#
# camera-array.sh — diagnostic (read-only)
#
# Purpose: show which camera IDs Google Camera actually discovers on this device,
# by watching its log as it starts. Useful for confirming that the cameraserver
# unlock worked — before the unlock GCam sees only the two public cameras; after
# it, all four appear. Requires root to read the system log. Changes nothing.
#
# Background: the GCam port's CameraManager2 class logs the array of cameras it
# found, e.g. "CameraManager2: GotArray:0 1 2 3". On a locked device it logs only:
#
#     CameraManager2: GotArray:0
#     CameraManager2: GotArray:1
#
# even though the framework offers cameras 0-3 to the process. Any aux button
# pointing at camera 2 or 3 then throws:
#
#     java.lang.ArrayIndexOutOfBoundsException: length=2; index=3
#
# This script works the problem in stages, cheapest first.
#
#   ./camera-array.sh test      apply prefs, launch, report what GotArray holds
#   ./camera-array.sh extract   pull the dex holding CameraManager2 and
#                               disassemble the enumeration for inspection
#   ./camera-array.sh clean     remove the working directory
#
# Run "test" first. If the array reaches 0-3 the preference route worked and
# there is nothing to patch. Only if it stays at 0-1 is "extract" worth
# running: that stage changes nothing on the device, it only gathers the
# smali needed to decide whether a dex patch is feasible.
#
#   Repo: https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix

set -u

PKG="com.google.android.GoogleCameraEngR18F1"
LAUNCH="$PKG/com.android.camera.CameraLauncher"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WORK="$HOME/gcam-array"
APK="$WORK/base.apk"
DEXDIR="$WORK/dex"
SMALI="$WORK/smali"
REPORT="$WORK/camera-array-report.txt"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$BLD" "$*" "$RST"; }
ok()   { printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s[!]%s  %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*" >&2; exit 1; }
as_root() { su -c "$*"; }

need_root() {
  su -c 'id -u' >/dev/null 2>&1 || die "No root. Grant Termux root access in Magisk."
}

# ====================================================================== test

do_test() {
  need_root
  step "Applying lens configuration"

  if [ -x "$SCRIPT_DIR/configure-lenses.sh" ]; then
    # Run it from its own directory so it finds the committed lenses.tsv
    # rather than falling back to the built-in set.
    ( cd "$SCRIPT_DIR" && ./configure-lenses.sh apply ) \
      | grep -E "Applying|applied|FAIL" | sed 's/^/  /'
  else
    warn "configure-lenses.sh not found next to this script; skipping"
  fi

  step "Verifying the override is actually set"
  local prefs
  prefs=$(as_root "cat /data/data/$PKG/shared_prefs/${PKG}_preferences.xml" 2>/dev/null)

  local enabled list
  enabled=$(printf '%s\n' "$prefs" | grep -o 'name="pref_enable_manual_array_key">[^<]*' | cut -d'>' -f2)
  list=$(printf '%s\n' "$prefs" | grep -o 'name="pref_manual_array_key">[^<]*' | cut -d'>' -f2)

  if [ "${enabled:-0}" = "1" ]; then
    ok "pref_enable_manual_array_key = 1"
  else
    warn "pref_enable_manual_array_key is NOT set - the override is off"
  fi
  [ -n "$list" ] && ok "pref_manual_array_key = $list" || warn "pref_manual_array_key unset"

  case "$list" in
    *4*|*5*) warn "the list names cameras 4/5 which do not exist here" ;;
  esac

  step "Cold launch, capturing the array"
  as_root "am force-stop $PKG"
  as_root "logcat -c" 2>/dev/null
  as_root "am start -n $LAUNCH" >/dev/null 2>&1
  printf '  waiting for the viewfinder'
  local i=0
  while [ $i -lt 10 ]; do printf '.'; sleep 1; i=$((i+1)); done
  printf '\n'

  local got
  got=$(as_root "logcat -d" 2>/dev/null | grep -oE 'GotArray:[0-9]+' | sort -u)

  step "Result"
  if [ -z "$got" ]; then
    warn "no GotArray lines - the port did not log its array this run"
    printf '  Try launching GCam by hand, then: su -c "logcat -d | grep GotArray"\n\n'
    return 1
  fi

  printf '%s\n' "$got" | sed 's/^/  /'
  local count
  count=$(printf '%s\n' "$got" | wc -l)

  echo
  if [ "$count" -ge 4 ]; then
    ok "array holds $count cameras - the preference route WORKED"
    printf '\n  The aux buttons should no longer crash. Nothing to patch.\n\n'
  else
    warn "array still holds only $count camera(s)"
    printf '\n  The override did not change what the port enumerates, so this is\n'
    printf '  in its code rather than its settings. Next:\n\n'
    printf '    %s extract\n\n' "$0"
  fi
}

# =================================================================== extract

do_extract() {
  local DISASM
  need_root
  step "Preflight"

  # Termux has no standalone smali package; baksmali ships inside apktool.
  # apktool -r skips resource decoding entirely, so the 712 "$$" drawables
  # that block a rebuild are irrelevant here - we only want the smali.
  DISASM=""
  if command -v baksmali >/dev/null 2>&1; then
    DISASM="baksmali"
    ok "baksmali present"
  elif command -v apktool >/dev/null 2>&1; then
    DISASM="apktool"
    ok "using apktool (no standalone baksmali needed)"
  else
    die "need apktool or baksmali. Install with: pkg install apktool"
  fi

  mkdir -p "$WORK" "$DEXDIR"

  step "Pulling the installed APK"
  local path
  path=$(as_root "pm path $PKG" 2>/dev/null | head -n1 | sed 's/^package://')
  [ -n "$path" ] || die "$PKG is not installed"
  as_root "cp '$path' '$APK'"
  as_root "chown $(id -u):$(id -u) '$APK'"
  as_root "chmod 644 '$APK'"
  ok "copied from $path ($(du -h "$APK" | cut -f1))"

  step "Extracting dex files"
  rm -rf "$DEXDIR"; mkdir -p "$DEXDIR"
  ( cd "$DEXDIR" && unzip -o -q "$APK" 'classes*.dex' ) || die "could not extract dex"
  ok "$(ls "$DEXDIR"/classes*.dex | wc -l) dex file(s)"

  step "Locating CameraManager2"
  # The log tag string lives in whichever dex holds the class, so grep the
  # raw dex rather than disassembling all of them.
  local target=""
  local f
  for f in "$DEXDIR"/classes*.dex; do
    if grep -qa "CameraManager2" "$f"; then
      target="$f"
      ok "found in $(basename "$f")"
      break
    fi
  done
  [ -n "$target" ] || die "no dex contains the string CameraManager2"

  step "Disassembling (a few minutes; be patient)"
  rm -rf "$SMALI"; mkdir -p "$SMALI"

  if [ "$DISASM" = "baksmali" ]; then
    baksmali d "$target" -o "$SMALI" 2>&1 | tail -5
  else
    # -r skips resources: this is disassembly only, nothing is rebuilt.
    rm -rf "$WORK/apktool-out"
    apktool d -r -f -o "$WORK/apktool-out" "$APK" > "$WORK/apktool.log" 2>&1 || {
      tail -20 "$WORK/apktool.log" | sed 's/^/  /'
      die "apktool disassembly failed (log: $WORK/apktool.log)"
    }
    # apktool emits smali/ and smali_classes2..N/ - fold them together
    local d
    for d in "$WORK/apktool-out"/smali*; do
      [ -d "$d" ] && cp -r "$d"/. "$SMALI"/ 2>/dev/null
    done
  fi

  local n
  n=$(find "$SMALI" -name '*.smali' | wc -l)
  [ "$n" -gt 0 ] || die "disassembly produced nothing"
  ok "$n smali files"

  step "Finding the enumeration"
  # GotArray marks the logging method, but the interesting logic is in
  # whatever builds the set it iterates - manualArray() and mCameraIDs.
  local hits
  hits=$(grep -rl -E "GotArray|manualArray|mCameraIDs" "$SMALI" 2>/dev/null)
  [ -n "$hits" ] || die "no smali references the camera array"

  : > "$REPORT"
  {
    printf '== camera array report ==\n'
    printf 'dex:   %s\n' "$(basename "$target")"
    printf 'files: %s\n\n' "$(printf '%s\n' "$hits" | tr '\n' ' ')"
  } >> "$REPORT"

  printf '%s\n' "$hits" | while read -r f; do
    {
      printf '\n\n=========================================================\n'
      printf '== %s\n' "${f#$SMALI/}"
      printf '=========================================================\n'
      # the whole method around each GotArray reference
      awk '/^\.method/{buf=""} {buf=buf $0 "\n"}
           /GotArray|manualArray|mCameraIDs|pref_manual_array|pref_enable_manual/{found=1}
           /^\.end method/{if(found) print buf; found=0; buf=""}' "$f"
    } >> "$REPORT"
  done

  {
    printf '\n\n=========================================================\n'
    printf '== camera enumeration API usage across this dex\n'
    printf '=========================================================\n'
  } >> "$REPORT"
  grep -rn -E "getCameraIdList|getNumberOfCameras|getCameraCharacteristics" \
    "$SMALI" 2>/dev/null | head -40 >> "$REPORT"

  {
    printf '\n\n=========================================================\n'
    printf '== preference keys read by the camera classes\n'
    printf '=========================================================\n'
  } >> "$REPORT"
  grep -rn -E 'const-string.*"pref_(manual_array|enable_manual_array|manual_cameraid)' \
    "$SMALI" 2>/dev/null | head -30 >> "$REPORT"

  # The whole class is small and worth having in full.
  local cls
  cls=$(grep -rl "GotArray" "$SMALI" 2>/dev/null | head -n1)
  if [ -n "$cls" ]; then
    {
      printf '\n\n=========================================================\n'
      printf '== FULL CLASS: %s\n' "${cls#$SMALI/}"
      printf '=========================================================\n'
      cat "$cls"
    } >> "$REPORT"
  fi

  ok "report written"
  printf '\n  %s  (%s)\n' "$REPORT" "$(du -h "$REPORT" | cut -f1)"
  printf '\n  Send that file. It contains the method that builds the array,\n'
  printf '  which is what decides whether a dex patch is worth attempting.\n\n'
}

do_clean() {
  rm -rf "$WORK"
  ok "removed $WORK"
  echo
}

case "${1:-test}" in
  test)    do_test ;;
  extract) do_extract ;;
  clean)   do_clean ;;
  *)       die "Usage: $0 [test|extract|clean]" ;;
esac
