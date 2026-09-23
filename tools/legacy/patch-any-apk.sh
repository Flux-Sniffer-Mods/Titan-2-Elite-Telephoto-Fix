#!/data/data/com.termux/files/usr/bin/bash
#
# patch-any-apk.sh
#
# Generalised version of gcam-titan2-build.sh: takes ANY APK, adds
# android.permission.SYSTEM_CAMERA to its manifest, re-signs it, and installs
# it as a privileged system app via its own Magisk module.
#
#   Repo: https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix
#
# The point of this on the Titan 2 Elite is diagnostic. The stock GCam port
# is granted SYSTEM_CAMERA (dumpsys confirms PRIVILEGED and granted=true) and
# the cameraserver still refuses:
#
#     getCameraCharacteristics: Unable to retrieve cameracharacteristics
#     for system only device 2
#
# Running a second, unrelated camera app through exactly the same pipeline
# separates two possibilities that otherwise look identical:
#
#   * the other app CAN read camera 2  -> the GCam port is the problem
#   * the other app CANNOT either      -> the platform is the problem, and
#                                         no port will ever work here
#
# Open Camera is a good subject: open source, camera2-based, and it lists
# every camera it finds in its own settings.
#
# Usage:
#   ./patch-any-apk.sh --apk FILE [--name DIRNAME] [--deploy]
#   ./patch-any-apk.sh --list          show modules this script created
#   ./patch-any-apk.sh --remove NAME   remove one of them
#
# Requires: root, Magisk, and
#   pkg install python apksigner openjdk-17 aapt zip unzip

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER="$SCRIPT_DIR/axml_add_perm.py"
VERIFIER="$SCRIPT_DIR/axml_verify.py"

PERMS="android.permission.SYSTEM_CAMERA android.permission.CAMERA_OPEN_CLOSE_LISTENER"

KS="$HOME/gcam.ks"
KSPASS="gcamkey123"
STAGE="/data/local/tmp/anyapk-stage"

APK_IN=""
DIRNAME=""
DEPLOY=0
ACTION="patch"
REMOVE_NAME=""

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$BLD" "$*" "$RST"; }
ok()   { printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s[!]%s  %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*" >&2; exit 1; }
as_root() { su -c "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apk)    shift; APK_IN="${1:?--apk needs a path}" ;;
    --name)   shift; DIRNAME="${1:?--name needs a value}" ;;
    --deploy) DEPLOY=1 ;;
    --list)   ACTION="list" ;;
    --remove) ACTION="remove"; shift; REMOVE_NAME="${1:?--remove needs a name}" ;;
    *) die "Usage: $0 --apk FILE [--name DIRNAME] [--deploy] | --list | --remove NAME" ;;
  esac
  shift
done

# ================================================================== list/rm

if [ "$ACTION" = "list" ]; then
  step "Modules created by this script"
  found=0
  for m in /data/adb/modules/privcam_*; do
    as_root "test -d '$m'" || continue
    found=1
    printf '  %-28s %s\n' "$(basename "$m")" \
      "$(as_root "grep -m1 '^description=' '$m/module.prop'" | sed 's/^description=//')"
  done
  [ "$found" = "1" ] || warn "none"
  echo; exit 0
fi

if [ "$ACTION" = "remove" ]; then
  M="/data/adb/modules/privcam_$REMOVE_NAME"
  as_root "test -d '$M'" || die "no module at $M"
  P=$(as_root "grep -m1 '^pkgname=' '$M/module.prop'" | sed 's/^pkgname=//')
  as_root "rm -rf '$M'"
  ok "removed $M"
  [ -n "$P" ] && as_root "pm uninstall $P" >/dev/null 2>&1 && ok "uninstalled $P"
  printf '\n  Reboot to finish.\n\n'
  exit 0
fi

# ================================================================= preflight

[ -n "$APK_IN" ] || die "need --apk FILE"
[ -f "$APK_IN" ] || die "no such file: $APK_IN"

step "Preflight"
su -c 'id -u' >/dev/null 2>&1 || die "No root. Grant Termux root access in Magisk."
as_root 'ls /data/adb/magisk' >/dev/null 2>&1 || die "Magisk not found"
[ -f "$PATCHER" ]  || die "axml_add_perm.py not found next to this script"
[ -f "$VERIFIER" ] || die "axml_verify.py not found next to this script"
for t in python3 apksigner keytool aapt zip unzip; do
  command -v "$t" >/dev/null 2>&1 || die "$t missing (pkg install python apksigner openjdk-17 aapt zip unzip)"
done
ok "toolchain present"

# ================================================================== identify

step "Identifying the APK"
PKG=$(aapt d badging "$APK_IN" 2>/dev/null | awk -F"'" '/^package: name=/{print $2}')
[ -n "$PKG" ] || die "could not read the package name (is this a valid APK?)"
LABEL=$(aapt d badging "$APK_IN" 2>/dev/null | awk -F"'" "/^application-label:/{print \$2; exit}")
ok "package: $PKG"
[ -n "$LABEL" ] && ok "label:   $LABEL"

# Native ABI dirs present in the APK decide whether libraries need unpacking.
ABIS=$(unzip -l "$APK_IN" 2>/dev/null | awk '/lib\/[a-z0-9-]+\//{split($4,a,"/"); print a[2]}' | sort -u)
[ -n "$ABIS" ] && ok "native ABIs: $(echo $ABIS | tr '\n' ' ')" || ok "no native libraries"

[ -n "$DIRNAME" ] || DIRNAME=$(printf '%s' "$PKG" | tr '.' '_' | tr -cd 'A-Za-z0-9_' | cut -c1-40)
MODID="privcam_$DIRNAME"
MODDIR="/data/adb/modules/$MODID"
APPDIR="$MODDIR/system/priv-app/$DIRNAME"
ok "module:  $MODID"

WORK="$HOME/privcam-$DIRNAME"
TMP="$WORK/tmp"
PATCHED="$WORK/patched.apk"
SIGNED="$WORK/signed.apk"
mkdir -p "$WORK" "$TMP"

# =================================================================== patch

step "Patching the manifest"
rm -rf "$TMP"; mkdir -p "$TMP"
( cd "$TMP" && unzip -o -q "$APK_IN" AndroidManifest.xml ) || die "could not extract manifest"
cp "$TMP/AndroidManifest.xml" "$WORK/AndroidManifest.orig.bin"

# shellcheck disable=SC2086
python3 "$PATCHER" "$WORK/AndroidManifest.orig.bin" "$TMP/AndroidManifest.xml" $PERMS \
  || die "manifest patch failed"
# shellcheck disable=SC2086
python3 "$VERIFIER" "$TMP/AndroidManifest.xml" $PERMS \
  || die "patched manifest failed validation"
ok "SYSTEM_CAMERA added and validated"

step "Repacking"
rm -f "$PATCHED" "$SIGNED"
cp "$APK_IN" "$PATCHED"
zip -d "$PATCHED" AndroidManifest.xml >/dev/null 2>&1 || die "could not drop old manifest"
( cd "$TMP" && zip -X "$PATCHED" AndroidManifest.xml >/dev/null ) || die "could not insert manifest"
unzip -l "$PATCHED" >/dev/null 2>&1 || die "repacked APK is invalid"
ok "repacked"

step "Signing"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -alias k -keyalg RSA -keysize 2048 \
    -validity 10000 -storepass "$KSPASS" -keypass "$KSPASS" \
    -dname "CN=privcam, O=local, C=US" >/dev/null 2>&1 || die "keystore creation failed"
  ok "created $KS"
else
  ok "reusing $KS"
fi
apksigner sign --ks "$KS" --ks-key-alias k --ks-pass "pass:$KSPASS" \
  --key-pass "pass:$KSPASS" --out "$SIGNED" "$PATCHED" || die "signing failed"
apksigner verify "$SIGNED" >/dev/null 2>&1 || die "signature verification failed"
aapt d permissions "$SIGNED" 2>/dev/null | grep -q SYSTEM_CAMERA \
  || die "SYSTEM_CAMERA absent from the finished APK"
ok "signed and confirmed"

if [ "$DEPLOY" != "1" ]; then
  printf '\n  Built: %s\n' "$SIGNED"
  printf '  Install with: %s --apk %s --deploy\n\n' "$0" "$APK_IN"
  exit 0
fi

# ================================================================== deploy

step "Removing existing copies of $PKG"
as_root "pm uninstall $PKG" >/dev/null 2>&1 && ok "uninstalled user copy" \
  || warn "no user-installed copy"

step "Building module $MODID"
as_root "rm -rf '$MODDIR'"
as_root "mkdir -p '$APPDIR' '$MODDIR/system/etc/permissions'"

as_root "rm -rf '$STAGE'; mkdir -p '$STAGE'"
cp "$SIGNED" "$STAGE/base.apk" 2>/dev/null || as_root "cp '$SIGNED' '$STAGE/base.apk'"
as_root "cp '$STAGE/base.apk' '$APPDIR/base.apk'" || die "could not place APK"
as_root "rm -rf '$STAGE'"
ok "APK placed"

# System apps get no automatic native-library extraction: /system is
# read-only, so PackageManager points nativeLibraryDir at <apk>/lib/<isa>
# and expects the files to already be there.
if [ -n "$ABIS" ]; then
  step "Unpacking native libraries"
  for abi in $ABIS; do
    case "$abi" in
      arm64-v8a)   isa="arm64" ;;
      armeabi-v7a) isa="arm" ;;
      x86_64)      isa="x86_64" ;;
      x86)         isa="x86" ;;
      *) warn "unknown ABI $abi, skipping"; continue ;;
    esac
    rm -rf "$WORK/libs"; mkdir -p "$WORK/libs"
    unzip -o -j -q "$SIGNED" "lib/$abi/*.so" -d "$WORK/libs" 2>/dev/null || continue
    n=$(find "$WORK/libs" -name '*.so' | wc -l)
    [ "$n" -gt 0 ] || continue
    as_root "mkdir -p '$APPDIR/lib/$isa'"
    as_root "cp '$WORK/libs'/*.so '$APPDIR/lib/$isa/'" || die "could not copy $abi libs"
    ok "$n library(ies) -> lib/$isa"
    rm -rf "$WORK/libs"
  done
fi

as_root "cat > '$MODDIR/module.prop'" <<EOF
id=$MODID
name=Privileged camera: ${LABEL:-$PKG}
version=1.0
versionCode=1
author=local
description=$PKG installed as a privileged app with SYSTEM_CAMERA
pkgname=$PKG
EOF

# Deliberately no system.prop. ro.control_privapp_permissions=log is
# device-wide and was found to break the telephoto lens in the stock
# MediaTek camera app on the Titan 2 Elite. Use Magisk safe mode if an
# allowlist mistake ever causes a bootloop.

as_root "cat > '$MODDIR/system/etc/permissions/privapp-permissions-$DIRNAME.xml'" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <privapp-permissions package="$PKG">
        <permission name="android.permission.SYSTEM_CAMERA"/>
        <permission name="android.permission.CAMERA_OPEN_CLOSE_LISTENER"/>
    </privapp-permissions>
</permissions>
EOF

# Clears any leftover "uninstalled for user 0" flag, which would otherwise
# leave the system app installed but hidden from the launcher.
as_root "cat > '$MODDIR/service.sh'" <<EOF
#!/system/bin/sh
until [ "\$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 5
pm install-existing $PKG >/dev/null 2>&1
EOF

as_root "chown -R 0:0 '$MODDIR'"
as_root "find '$MODDIR' -type d -exec chmod 0755 {} +"
as_root "find '$MODDIR' -type f -exec chmod 0644 {} +"
as_root "chmod 0755 '$MODDIR/service.sh'"
ok "module written"

printf '\n%s================================================%s\n' "$BLD" "$RST"
printf '%s  Done. REBOOT now.%s\n' "$GRN" "$RST"
printf '%s================================================%s\n\n' "$BLD" "$RST"
printf '  After reboot, check it took:\n'
printf '    su -c "dumpsys package %s | grep -E \\"privateFlags=|SYSTEM_CAMERA\\""\n\n' "$PKG"
printf '  Then open the app and see whether it lists cameras 2 and 3.\n'
printf '  Remove again with: %s --remove %s\n\n' "$0" "$DIRNAME"
