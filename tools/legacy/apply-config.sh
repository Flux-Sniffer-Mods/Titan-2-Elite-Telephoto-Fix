#!/data/data/com.termux/files/usr/bin/bash
#
# apply-config.sh — install the corrected GCam config for the telephoto
#
# Writes gcam_config_fixed.xml into the GCam port's shared_prefs with the
# app's own ownership and SELinux context, so it reads it back. Force-stops
# GCam first (SharedPreferences are cached in memory and overwritten on exit).
#
# Usage: ./apply-config.sh [path-to-config.xml]   (defaults to ./gcam_config_fixed.xml)

set -u
P=com.google.android.GoogleCameraEngR18F1
PREFS=/data/data/$P/shared_prefs/${P}_preferences.xml
SRC="${1:-$(dirname "$0")/gcam_config_fixed.xml}"
T=/data/local/tmp/gcam_cfg.xml
# absolute Termux python3 (this script runs as the Termux user; keep the path
# explicit so it resolves the same regardless of the caller's namespace)
PY3="$(command -v python3 || echo /data/data/com.termux/files/usr/bin/python3)"

RED=$'\033[31m'; GRN=$'\033[32m'; BLD=$'\033[1m'; RST=$'\033[0m'
ok(){ printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
die(){ printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*"; exit 1; }

su -c 'id -u' >/dev/null 2>&1 || die "no root"
[ -f "$SRC" ] || die "config not found: $SRC"
[ -x "$PY3" ] || die "python3 not found at $PY3"
"$PY3" -c "import xml.dom.minidom;xml.dom.minidom.parse('$SRC')" 2>/dev/null || die "config is not valid XML"
su -c "test -d /data/data/$P" || die "$P not installed"

printf '%s==> Applying GCam telephoto config%s\n' "$BLD" "$RST"
su -c "am force-stop $P"
ok "GCam stopped"

# stage through /data/local/tmp (namespace-stable), then place as the app uid
cp "$SRC" "$T" 2>/dev/null || su -c "cp '$SRC' $T"
su -c "chmod 644 $T"
OWNER=$(su -c "stat -c '%u:%g' /data/data/$P")
su -c "mkdir -p /data/data/$P/shared_prefs"
su -c "cp $T $PREFS"
su -c "chown $OWNER $PREFS"
su -c "chmod 660 $PREFS"
su -c "restorecon $PREFS" 2>/dev/null
su -c "rm -f $T"
ok "config written (owner $OWNER)"

# --- verify the prefs actually landed, else fail loudly (nonzero exit) -------
# read it back as root, confirm it parses and carries the telephoto keys.
RB="$(su -c "cat $PREFS" 2>/dev/null)"
[ -n "$RB" ] || die "read-back failed: $PREFS is empty or unreadable"
printf '%s' "$RB" | "$PY3" -c "import sys,xml.dom.minidom;xml.dom.minidom.parseString(sys.stdin.read())" 2>/dev/null \
  || die "read-back failed: installed prefs are not valid XML"
printf '%s' "$RB" | grep -q '_tele"' \
  || die "read-back failed: installed prefs carry no telephoto keys"
GOTOWNER="$(su -c "stat -c '%u:%g' $PREFS" 2>/dev/null)"
[ "$GOTOWNER" = "$OWNER" ] \
  || die "read-back failed: prefs owner is $GOTOWNER, expected $OWNER (GCam would ignore it)"
ok "config verified in place (valid XML, telephoto keys present, owner $GOTOWNER)"

su -c "am start -n $P/com.android.camera.CameraLauncher" >/dev/null 2>&1
ok "GCam launched"
printf '\n  Telephoto button = 3.4x (camera 2, real tele, no-RAW photo path).\n'
printf '  Photo mode should now render. If it still blacks out, edit\n'
printf '  pref_model_key_tele in the config (try 0,1,2) and re-apply.\n\n'
