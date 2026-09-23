#!/data/data/com.termux/files/usr/bin/bash
#
# gcam-titan2-build.sh
#
# Makes the telephoto camera on a rooted Unihertz Titan 2 Elite visible to
# a Google Camera port, by granting the app android.permission.SYSTEM_CAMERA.
#
#   Repo: https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix
#   APK:  https://drive.google.com/file/d/1hfPL8ggZIZOc4Uho4DR4B7cVhlMwGHp_/view?usp=sharing
#
# See README.md for the full explanation of why this is necessary.
# Short version: cameras 2 and 3 are flagged SYSTEM_CAMERA by the vendor
# HAL, so since Android 11 they are invisible to any app that lacks that
# signature|privileged permission. Granting it needs two things, and both
# are required - either alone does nothing:
#
#   1. the APK must DECLARE the permission in its manifest
#   2. the app must be installed as a PRIVILEGED system app, with a
#      privapp-permissions allowlist entry
#
# Run modes:
#   ./gcam-titan2-build.sh            build, patch, sign, install
#                                     (downloads the APK if it is missing)
#   ./gcam-titan2-build.sh fetch      download the APK only
#   ./gcam-titan2-build.sh verify     post-reboot health check
#   ./gcam-titan2-build.sh restore    undo everything
#
# Requires: Termux, root (Magisk), and
#   pkg install python apksigner openjdk-17 zip unzip aapt
#
# Note that apktool is NOT required. See README.md, "Why not apktool".

set -u

# ============================================================== configuration

PKG="com.google.android.GoogleCameraEngR18F1"
APK_NAME="IlluminatiEliteGCam_v1.4_Titan2Elite.apk"

# Google Drive file id for the stock port. Fetched with gdown rather than
# curl: Drive interposes a confirmation page on files this large, and a
# plain download silently saves that HTML page instead of the APK.
APK_DRIVE_ID="1hfPL8ggZIZOc4Uho4DR4B7cVhlMwGHp_"

# arm64-v8a is the APK's ABI directory name; "arm64" is the instruction-set
# directory name Android expects for a bundled system app. They differ.
APK_ABI_DIR="arm64-v8a"
SYSTEM_ISA_DIR="arm64"

PERMS="android.permission.SYSTEM_CAMERA android.permission.CAMERA_OPEN_CLOSE_LISTENER"

MODID="gcam_priv"
MODDIR="/data/adb/modules/$MODID"
APPDIR="$MODDIR/system/priv-app/GoogleCameraEng"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER="$SCRIPT_DIR/axml_add_perm.py"
VERIFIER="$SCRIPT_DIR/axml_verify.py"

WORK="$HOME/gcam-build"
ORIG="$WORK/$APK_NAME"
TMP="$WORK/tmp"
LIBS="$WORK/libs"
MANIFEST_ORIG="$WORK/AndroidManifest.orig.bin"
PATCHED="$WORK/gcam-patched.apk"
SIGNED="$WORK/gcam-signed.apk"

KS="$HOME/gcam.ks"
KSPASS="gcamkey123"

BACKUP="$HOME/gcam-backup-$(date +%Y%m%d-%H%M%S)"
STAGE="/data/local/tmp/gcam-stage"   # readable by both Termux and root

# ==================================================================== output

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'

step() { printf '\n%s==> %s%s\n' "$BLD" "$*" "$RST"; }
ok()   { printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s[!]%s  %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*" >&2; exit 1; }

as_root() { su -c "$*"; }

# ================================================================= preflight

preflight() {
  step "Preflight"

  [ -d /data/data/com.termux ] || die "Run this inside Termux."

  su -c 'id -u' >/dev/null 2>&1 || die "No root. Grant Termux root access in Magisk."
  [ "$(su -c 'id -u')" = "0" ] || die "su did not return uid 0."
  ok "root available"

  as_root 'ls /data/adb/magisk' >/dev/null 2>&1 \
    || die "Magisk not found at /data/adb/magisk."
  ok "Magisk present"

  [ -f "$PATCHER" ]  || die "axml_add_perm.py not found next to this script."
  [ -f "$VERIFIER" ] || die "axml_verify.py not found next to this script."
  ok "helper scripts found"

  local missing=""
  local t
  for t in python3 apksigner keytool zip unzip; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done

  if [ -n "$missing" ]; then
    warn "missing tools:$missing"
    printf '  Install them now with pkg? [y/N] '
    read -r answer
    case "$answer" in
      y|Y) pkg install -y python apksigner openjdk-17 zip unzip aapt \
             || die "pkg install failed" ;;
      *)   die "Install first: pkg install python apksigner openjdk-17 zip unzip aapt" ;;
    esac
    for t in python3 apksigner keytool zip unzip; do
      command -v "$t" >/dev/null 2>&1 || die "$t is still missing"
    done
  fi
  ok "toolchain present (apktool not required)"

  command -v aapt >/dev/null 2>&1 \
    || warn "aapt absent - the optional cross-check of the final APK will be skipped"
}

# ==================================================================== backup

backup_configs() {
  step "Backing up GCam configs"

  # Different ports scatter their saved configs across these paths. They are
  # the only thing here that cannot be regenerated, so save them all first.
  mkdir -p "$BACKUP"
  local found=0 dir
  for dir in /sdcard/GCam /sdcard/GCamEng /sdcard/Configs7 /sdcard/Configs \
             "/sdcard/Android/data/$PKG"; do
    if as_root "test -e '$dir'"; then
      as_root "cp -r '$dir' '$BACKUP/'" 2>/dev/null && { ok "saved $dir"; found=1; }
    fi
  done
  as_root "chown -R $(id -u):$(id -u) '$BACKUP'" 2>/dev/null

  [ "$found" = "1" ] || warn "no existing configs found (expected on a first run)"
  ok "backup directory: $BACKUP"
}

# ================================================================= fetch apk

fetch_apk() {
  step "Downloading $APK_NAME"
  mkdir -p "$WORK"

  if ! command -v gdown >/dev/null 2>&1; then
    command -v pip >/dev/null 2>&1 || die "pip not available; run: pkg install python"
    ok "installing gdown"
    pip install -q -U gdown || die "could not install gdown"
  fi

  gdown "$APK_DRIVE_ID" -O "$ORIG" || die "download failed"

  # A Drive confirmation page is small HTML; a real APK is a large zip.
  # Catch the former before it fails confusingly later.
  unzip -l "$ORIG" >/dev/null 2>&1 \
    || die "the downloaded file is not a valid APK.
       Drive most likely returned its confirmation page.
       Download manually instead:
         https://drive.google.com/file/d/$APK_DRIVE_ID/view"

  ok "downloaded $(du -h "$ORIG" | cut -f1) to $ORIG"
}

# ================================================================ locate apk

locate_apk() {
  step "Locating $APK_NAME"
  mkdir -p "$WORK" "$TMP"

  if [ -f "$ORIG" ]; then
    ok "using $ORIG"
    return
  fi

  local candidate
  for candidate in "$HOME/$APK_NAME" \
                   "/sdcard/Download/$APK_NAME" \
                   "/sdcard/$APK_NAME" \
                   "$HOME/storage/downloads/$APK_NAME"; do
    if [ -f "$candidate" ]; then
      cp "$candidate" "$ORIG" && ok "copied from $candidate" && return
    fi
  done

  # Last resort: pull whatever copy is currently installed.
  local installed
  installed=$(as_root "pm path $PKG" 2>/dev/null \
                | grep '^package:' | head -n1 | sed 's/^package://')

  if [ -n "$installed" ]; then
    case "$installed" in
      /system/*)
        die "Only a /system copy exists (this script's own output).
       Put the pristine $APK_NAME in $WORK/ and re-run." ;;
    esac
    as_root "cp '$installed' '$ORIG'"
    as_root "chmod 644 '$ORIG'"
    as_root "chown $(id -u):$(id -u) '$ORIG'"
    ok "pulled installed copy from $installed"
    return
  fi

  warn "$APK_NAME not found locally"
  printf '  Download it now (about 200 MB, from Google Drive)? [Y/n] '
  read -r answer
  case "$answer" in
    n|N) die "Place $APK_NAME in $WORK/ or /sdcard/Download/ and re-run.
       https://drive.google.com/file/d/$APK_DRIVE_ID/view" ;;
    *)   fetch_apk ;;
  esac
}

# =========================================================== patch manifest

patch_manifest() {
  step "Patching the compiled AndroidManifest.xml"

  rm -rf "$TMP"; mkdir -p "$TMP"

  # Pull the binary manifest straight out of the APK. Nothing else is
  # extracted, so the 712 "$$"-named resources never reach a compiler.
  ( cd "$TMP" && unzip -o -q "$ORIG" AndroidManifest.xml ) \
    || die "could not extract AndroidManifest.xml from the APK"
  [ -s "$TMP/AndroidManifest.xml" ] || die "extracted manifest is empty"

  cp "$TMP/AndroidManifest.xml" "$MANIFEST_ORIG"

  # shellcheck disable=SC2086  # PERMS is an intentional word list
  python3 "$PATCHER" "$MANIFEST_ORIG" "$TMP/AndroidManifest.xml" $PERMS \
    || die "manifest patch failed"

  # Validate with an independent reader, not the patcher's own logic.
  # shellcheck disable=SC2086
  python3 "$VERIFIER" "$TMP/AndroidManifest.xml" $PERMS \
    || die "patched manifest failed validation - nothing was installed"

  ok "manifest patched and independently validated"
}

# ==================================================================== repack

repack() {
  step "Repacking the APK"

  rm -f "$PATCHED" "$SIGNED"
  cp "$ORIG" "$PATCHED" || die "could not copy the original APK"

  # Replace only the manifest entry. Every other entry - resources.arsc,
  # the dex files, the native libs - is carried over untouched.
  zip -d "$PATCHED" AndroidManifest.xml >/dev/null 2>&1 \
    || die "could not remove the old manifest from the zip"
  ( cd "$TMP" && zip -X "$PATCHED" AndroidManifest.xml >/dev/null ) \
    || die "could not insert the patched manifest"

  unzip -l "$PATCHED" >/dev/null 2>&1 || die "the repacked APK is not a valid zip"
  ok "manifest swapped, all other entries preserved"

  # The manifest declares extractNativeLibs="true", so the .so files are
  # compressed and do not need page alignment. zipalign is still good
  # hygiene for resources.arsc when it is available.
  if command -v zipalign >/dev/null 2>&1; then
    if zipalign -p -f 4 "$PATCHED" "$PATCHED.aligned"; then
      mv "$PATCHED.aligned" "$PATCHED"
      ok "zipaligned"
    else
      rm -f "$PATCHED.aligned"
      warn "zipalign failed; continuing (targetSdk is 29, so it is tolerated)"
    fi
  else
    warn "zipalign not installed; skipping (safe here, targetSdk is 29)"
  fi
}

# ====================================================================== sign

sign() {
  step "Signing"

  # A self-signed throwaway key. It only ever signs this local APK, but keep
  # the keystore: Android ties package identity to the signing key, so losing
  # it means future updates require uninstall + reinstall, wiping app data.
  if [ ! -f "$KS" ]; then
    keytool -genkeypair -keystore "$KS" -alias k \
      -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass "$KSPASS" -keypass "$KSPASS" \
      -dname "CN=gcam, O=local, C=US" >/dev/null 2>&1 \
      || die "keystore creation failed"
    ok "created keystore $KS (password: $KSPASS) - keep this file"
  else
    ok "reusing keystore $KS"
  fi

  apksigner sign --ks "$KS" --ks-key-alias k \
    --ks-pass "pass:$KSPASS" --key-pass "pass:$KSPASS" \
    --out "$SIGNED" "$PATCHED" \
    || die "apksigner sign failed"

  apksigner verify "$SIGNED" >/dev/null 2>&1 \
    || die "signature verification failed"
  ok "signed and verified"
}

cross_check() {
  step "Cross-checking the finished APK with aapt"

  if ! command -v aapt >/dev/null 2>&1; then
    warn "aapt absent - skipping (the manifest validator already passed)"
    return
  fi

  if aapt d permissions "$SIGNED" 2>/dev/null \
      | grep -q "android.permission.SYSTEM_CAMERA"; then
    ok "aapt confirms SYSTEM_CAMERA is declared"
  else
    die "aapt cannot see SYSTEM_CAMERA in the finished APK.
       Stop here - installing this would change nothing."
  fi
}

# ==================================================================== deploy

deploy() {
  step "Removing existing copies of $PKG"

  # A privileged copy and a user-installed copy of the same package conflict,
  # and the app will not start. Remove the user-installed copy first.
  #
  # Note: deliberately NOT "pm uninstall --user 0". For a package that is
  # about to reappear in /system/priv-app, that does not delete anything -
  # it sets a per-user "uninstalled" flag. PackageManager then scans the
  # system copy, installs it, and honours the flag by hiding it. The result
  # is an app that is installed and invisible. service.sh below clears that
  # state on boot for the case where it was set by some earlier run.
  as_root "pm uninstall $PKG" >/dev/null 2>&1 \
    && ok "uninstalled user copy" || warn "no user-installed copy present"

  step "Building the Magisk module"

  as_root "rm -rf '$MODDIR'"
  as_root "mkdir -p '$APPDIR' '$MODDIR/system/etc/permissions'"

  # Termux's home is not readable by system_server or by root's cp in all
  # configurations, so hand the file over via /data/local/tmp.
  as_root "rm -rf '$STAGE'; mkdir -p '$STAGE'"
  cp "$SIGNED" "$STAGE/base.apk" 2>/dev/null || as_root "cp '$SIGNED' '$STAGE/base.apk'"
  as_root "cp '$STAGE/base.apk' '$APPDIR/base.apk'" \
    || die "could not place the APK into the module"
  as_root "rm -rf '$STAGE'"
  ok "APK placed in priv-app"

  install_native_libs
  write_module_metadata

  as_root "chown -R 0:0 '$MODDIR'"
  as_root "find '$MODDIR' -type d -exec chmod 0755 {} +"
  as_root "find '$MODDIR' -type f -exec chmod 0644 {} +"
  # must come after the blanket chmod above, which would otherwise strip +x
  as_root "chmod 0755 '$MODDIR/service.sh'"

  as_root "test -f '$APPDIR/base.apk'" || die "module APK missing after write"
  as_root "test -x '$MODDIR/service.sh'" || die "service.sh is not executable"
  as_root "test -f '$APPDIR/lib/$SYSTEM_ISA_DIR/libgcastartup.so'" \
    || die "libgcastartup.so missing - GCam would crash instantly"
  ok "module contents verified"
}

install_native_libs() {
  step "Installing native libraries"

  # A normally-installed app has its .so files unpacked to
  # /data/app/<pkg>/lib/arm64 at install time. A system app does not:
  # /system is read-only, so PackageManager skips extraction and simply
  # points nativeLibraryDir at <apk dir>/lib/<isa>. If we do not unpack
  # them ourselves, the very first System.loadLibrary call throws
  # UnsatisfiedLinkError and the app dies before showing a viewfinder.

  rm -rf "$LIBS"; mkdir -p "$LIBS"
  unzip -o -j -q "$SIGNED" "lib/$APK_ABI_DIR/*.so" -d "$LIBS" \
    || die "could not extract native libraries from the APK"

  local count
  count=$(find "$LIBS" -name '*.so' | wc -l)
  [ "$count" -gt 0 ] || die "no .so files were extracted"
  ok "$count libraries extracted ($(du -sh "$LIBS" | cut -f1))"

  as_root "mkdir -p '$APPDIR/lib/$SYSTEM_ISA_DIR'"
  as_root "cp '$LIBS'/*.so '$APPDIR/lib/$SYSTEM_ISA_DIR/'" \
    || die "could not copy native libraries into the module"
  rm -rf "$LIBS"
  ok "libraries installed to lib/$SYSTEM_ISA_DIR"
}

write_module_metadata() {
  step "Writing module metadata"

  as_root "cat > '$MODDIR/module.prop'" <<EOF
id=$MODID
name=GCam Privileged (SYSTEM_CAMERA)
version=2.1
versionCode=4
author=local
description=Installs a manifest-patched GCam port as a privileged app with SYSTEM_CAMERA, exposing hidden camera IDs 2 and 3.
EOF

  # NOT written any more. Setting ro.control_privapp_permissions=log here
  # was found to break the telephoto lens in the STOCK MediaTek camera app
  # on the Titan 2 Elite - device-wide, and despite com.mediatek.camera
  # being SYSTEM_EXT rather than PRIVILEGED. Some privileged component in
  # MediaTek's camera stack evidently loses a grant when enforcement is
  # relaxed. The allowlist below is correct, so the safety net is not
  # needed; if a future change does cause a bootloop, use Magisk safe mode
  # (Volume Down during boot) rather than reinstating this.

  as_root "cat > '$MODDIR/system/etc/permissions/privapp-permissions-gcam.xml'" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <privapp-permissions package="$PKG">
        <permission name="android.permission.SYSTEM_CAMERA"/>
        <permission name="android.permission.CAMERA_OPEN_CLOSE_LISTENER"/>
    </privapp-permissions>
</permissions>
EOF

  # Runs late in boot, once PackageManager is up. Clears any leftover
  # "uninstalled for user 0" flag, which would otherwise leave the system
  # app installed but hidden from the launcher. Harmless when already
  # visible - install-existing is idempotent.
  as_root "cat > '$MODDIR/service.sh'" <<EOF
#!/system/bin/sh
until [ "\$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 5
pm install-existing $PKG >/dev/null 2>&1
EOF

  ok "module.prop, allowlist and service.sh written"
}

# ==================================================================== verify

do_verify() {
  step "Package state"

  local path flags
  path=$(as_root "pm path $PKG" 2>/dev/null | head -n1)

  if [ -z "$path" ]; then
    # Distinguish "not there at all" from "installed but hidden for user 0".
    if as_root "pm list packages -u" 2>/dev/null | grep -q "$PKG"; then
      warn "package is installed but hidden for this user"
      printf '  Re-enabling it now...\n'
      as_root "pm install-existing $PKG" >/dev/null 2>&1
      path=$(as_root "pm path $PKG" 2>/dev/null | head -n1)
      [ -n "$path" ] && ok "re-enabled" || die "pm install-existing did not help"
    else
      die "$PKG is not installed at all. Check Magisk > Modules, and that
       /system/priv-app/GoogleCameraEng/base.apk exists after reboot."
    fi
  fi

  echo "  codePath: $path"
  case "$path" in
    *priv-app*) ok "running from priv-app" ;;
    *)          warn "NOT in priv-app - the module did not take effect" ;;
  esac

  # dumpsys reports two separate fields. PRIVILEGED lives in privateFlags=,
  # never in flags=, so both must be read.
  flags=$(as_root "dumpsys package $PKG" 2>/dev/null | grep -m1 "  flags=")
  pflags=$(as_root "dumpsys package $PKG" 2>/dev/null | grep -m1 "privateFlags=")
  [ -n "$flags" ]  && echo "  $flags"
  [ -n "$pflags" ] && echo "  $pflags"
  case "$flags$pflags" in
    *PRIVILEGED*) ok "PRIVILEGED flag set" ;;
    *)            warn "PRIVILEGED flag absent in both flags and privateFlags" ;;
  esac

  if as_root "dumpsys package $PKG" 2>/dev/null \
      | grep -q "android.permission.SYSTEM_CAMERA.*granted=true"; then
    ok "SYSTEM_CAMERA granted"
  else
    warn "SYSTEM_CAMERA not granted - recent allowlist warnings:"
    as_root "logcat -d -s PackageManager:W" 2>/dev/null \
      | grep -i privapp | tail -5 | sed 's/^/    /'
  fi

  step "Native libraries"
  local libdir="$APPDIR/lib/$SYSTEM_ISA_DIR"
  if as_root "test -d '$libdir'"; then
    ok "$(as_root "ls '$libdir' | wc -l") libraries present"
    if as_root "test -f '$libdir/libgcastartup.so'"; then
      ok "libgcastartup.so present"
    else
      warn "libgcastartup.so MISSING - this causes an instant crash on launch"
    fi
  else
    warn "lib/$SYSTEM_ISA_DIR missing entirely - GCam will crash on launch"
  fi

  step "Camera inventory"
  as_root "dumpsys media.camera" 2>/dev/null \
    | grep -E "Number of camera|static information|^ +Facing" | sed 's/^/  /'

  printf '\n  %sIn GCam:%s look for cameras 2 and 3 in the aux/lens settings.\n' "$BLD" "$RST"
  printf '  Prefer camera 3 - it is the logical device, and the one with RAW.\n\n'
}

# =================================================================== restore

do_restore() {
  step "Restoring"

  as_root "rm -rf '$MODDIR'" && ok "module removed"
  as_root "pm uninstall $PKG" >/dev/null 2>&1 \
    && ok "package uninstalled" || warn "nothing to uninstall"
  rm -f "$PATCHED" "$SIGNED"
  ok "build artifacts cleared (keystore and config backups kept)"

  printf '\n  Reboot, then install the original APK normally.\n\n'
}

# ======================================================================= main

main() {
  case "${1:-run}" in
    fetch)   fetch_apk; exit 0 ;;
    verify)  preflight; do_verify;  exit 0 ;;
    restore) preflight; do_restore; exit 0 ;;
    run)     ;;
    *)       die "Usage: $0 [run|fetch|verify|restore]" ;;
  esac

  preflight
  backup_configs
  locate_apk
  patch_manifest
  repack
  sign
  cross_check
  deploy

  printf '\n%s================================================%s\n' "$BLD" "$RST"
  printf '%s  Done. REBOOT now.%s\n'                                "$GRN" "$RST"
  printf '%s================================================%s\n\n' "$BLD" "$RST"
  printf '  After reboot:     %s verify\n'   "$0"
  printf '  If it bootloops:  hold Volume Down during boot for Magisk\n'
  printf '                    safe mode, then run: %s restore\n\n' "$0"
  printf '  Configs saved to: %s\n' "$BACKUP"
  printf '  Keystore (keep):  %s\n\n' "$KS"
}

main "$@"
