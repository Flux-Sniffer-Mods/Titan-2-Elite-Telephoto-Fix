#!/system/bin/sh
# Titan 2 Elite Telephoto — FULL module boot service.
#   1. reapply the cameraserver telephoto unlock (RAM patch, lost each boot)
#   2. install/refresh the bundled TeleZoom app
#   3. install the bundled patched GCam ONCE (first boot after flashing)
MODDIR="${0%/*}"
LOG(){ log -t titan2-telephoto "$*"; }
STAGE=/data/local/tmp

# wait for a usable system
i=0; while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 60 ]; do sleep 2; i=$((i+1)); done
i=0; while [ -z "$(pidof cameraserver)" ] && [ $i -lt 30 ]; do sleep 2; i=$((i+1)); done
sleep 5

# 1. unlock
sh "$MODDIR/unlock-cameraserver.sh" apply && LOG "unlock applied" || LOG "unlock FAILED"

apkver(){ pm dump "$1" 2>/dev/null | grep -m1 versionCode | grep -oE '[0-9]+' | head -1; }
pkgver(){ dumpsys package "$1" 2>/dev/null | grep -m1 versionCode | grep -oE 'versionCode=[0-9]+' | grep -oE '[0-9]+' | head -1; }
stage(){ cp "$1" "$STAGE/_m.apk" && chmod 644 "$STAGE/_m.apk"; }

# 2. TeleZoom app
APK="$MODDIR/telezoom.apk"
if [ -f "$APK" ]; then
  PKG=com.fluxsniffer.telezoom
  want="$(apkver "$APK")"; have="$(pkgver "$PKG")"
  if [ -z "$have" ] || { [ -n "$want" ] && [ "$want" -gt "${have:-0}" ] 2>/dev/null; }; then
    stage "$APK"
    pm install -r "$STAGE/_m.apk" >/dev/null 2>&1 || { pm uninstall "$PKG" >/dev/null 2>&1; pm install "$STAGE/_m.apk" >/dev/null 2>&1; }
    LOG "TeleZoom app installed/updated (v${want:-?})"
  else LOG "TeleZoom app up to date (v${have})"; fi
fi

# 3. patched GCam — install once (sentinel), replacing any existing copy of the pkg
GCAM="$MODDIR/gcam-patched.apk"
SENT="$MODDIR/.gcam_installed"
if [ -f "$GCAM" ] && [ ! -f "$SENT" ]; then
  PKG="$(cat "$MODDIR/gcam-pkg" 2>/dev/null)"; [ -n "$PKG" ] || PKG=com.google.android.GoogleCameraEngR18F1
  stage "$GCAM"
  ok=0
  for try in 1 2 3; do
    if pm install -r "$STAGE/_m.apk" >/dev/null 2>&1; then ok=1; break; fi
    # signature mismatch vs an existing (unpatched) GCam -> replace it
    pm uninstall "$PKG" >/dev/null 2>&1
    if pm install "$STAGE/_m.apk" >/dev/null 2>&1; then ok=1; break; fi
    LOG "GCam install attempt $try failed; retrying"; sleep 5
  done
  if [ "$ok" = 1 ] && [ -n "$(pm path "$PKG" 2>/dev/null)" ]; then
    touch "$SENT"; LOG "patched GCam installed ($PKG)"
  else
    LOG "patched GCam install FAILED — will retry next boot"
  fi
fi
rm -f "$STAGE/_m.apk" 2>/dev/null
LOG "boot service done"
