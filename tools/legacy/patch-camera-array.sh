#!/data/data/com.termux/files/usr/bin/bash
#
# patch-camera-array.sh
#
# Forces the port's camera array to contain all four camera IDs by patching
# a single method, com/eszdman->manualArray(), in the dex.
#
#   Repo: https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix
#
# Background: getCameraIdList() prefers manualArray() and only falls back to
# the auto-detected mCameraIDs when it is empty. Hardcoding manualArray() to
# return {0,1,2,3} makes the port see every camera regardless of settings,
# so the aux buttons stop throwing ArrayIndexOutOfBoundsException.
#
# Why this rebuilds at all, when the README says rebuilding is impossible:
# "apktool d -r" skips resource DECODING, so "apktool b" never runs aapt2
# over the 712 "$$"-named drawables that block a normal rebuild. Only the
# smali is touched.
#
# Usage:
#   ./patch-camera-array.sh              patch, build, sign
#   ./patch-camera-array.sh --deploy     also install into the Magisk module
#   ./patch-camera-array.sh --keep       leave the workspace for inspection

set -u

PKG="com.google.android.GoogleCameraEngR18F1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WORK="$HOME/gcam-dexpatch"
SRC_APK="$WORK/source.apk"
DECODED="$WORK/decoded"
BUILT="$WORK/built.apk"
SIGNED="$WORK/gcam-arraypatched.apk"

# Reuse the build script's keystore so the package signature stays stable;
# a new key would force an uninstall and wipe app data.
KS="$HOME/gcam.ks"
KSPASS="gcamkey123"

MODDIR="/data/adb/modules/gcam_priv"
APPDIR="$MODDIR/system/priv-app/GoogleCameraEng"

DEPLOY=0
KEEP=0

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$BLD" "$*" "$RST"; }
ok()   { printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s[!]%s  %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*" >&2; exit 1; }
as_root() { su -c "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --deploy) DEPLOY=1 ;;
    --keep)   KEEP=1 ;;
    *) die "Usage: $0 [--deploy] [--keep]" ;;
  esac
  shift
done

# ================================================================= preflight

step "Preflight"
for t in apktool keytool apksigner unzip zip python3; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found (pkg install apktool openjdk-17 apksigner zip unzip python)"
done
ok "toolchain present"

mkdir -p "$WORK"

# ================================================================ source apk
#
# Order matters. The INSTALLED apk already carries the SYSTEM_CAMERA manifest
# patch; the pristine download does not. Rebuilding from the wrong one throws
# that patch away and silently undoes the whole telephoto fix.

step "Selecting source APK"
SRC=""
if command -v su >/dev/null 2>&1 && su -c 'id -u' >/dev/null 2>&1; then
  p=$(as_root "pm path $PKG" 2>/dev/null | head -n1 | sed 's/^package://')
  if [ -n "$p" ]; then
    as_root "cp '$p' '$SRC_APK'"
    as_root "chown $(id -u):$(id -u) '$SRC_APK'"
    as_root "chmod 644 '$SRC_APK'"
    SRC="installed copy ($p)"
  fi
fi
if [ -z "$SRC" ]; then
  for c in "$HOME/gcam-build/gcam-signed.apk" \
           "$HOME/gcam-build/IlluminatiEliteGCam_v1.4_Titan2Elite.apk" \
           "/sdcard/Download/IlluminatiEliteGCam_v1.4_Titan2Elite.apk"; do
    [ -f "$c" ] && cp "$c" "$SRC_APK" && SRC="$c" && break
  done
fi
[ -n "$SRC" ] || die "no source APK found. Run gcam-titan2-build.sh first."
ok "using $SRC"

if aapt d permissions "$SRC_APK" 2>/dev/null | grep -q SYSTEM_CAMERA; then
  ok "source already declares SYSTEM_CAMERA"
  HAD_PERM=1
else
  warn "source does NOT declare SYSTEM_CAMERA"
  warn "the result will need gcam-titan2-build.sh run over it afterwards"
  HAD_PERM=0
fi

# =================================================================== decode

step "Decoding (resources skipped)"
rm -rf "$DECODED"
apktool d -r -f -o "$DECODED" "$SRC_APK" > "$WORK/decode.log" 2>&1 \
  || { tail -20 "$WORK/decode.log" | sed 's/^/  /'; die "apktool d failed"; }
ok "decoded"

step "Locating com/eszdman.smali"
TARGET=""
for d in "$DECODED"/smali*; do
  [ -f "$d/com/eszdman.smali" ] && TARGET="$d/com/eszdman.smali" && break
done
[ -n "$TARGET" ] || die "com/eszdman.smali not found in the decoded output"
ok "${TARGET#$DECODED/}"

cp "$TARGET" "$WORK/eszdman.smali.orig"

# ==================================================================== patch
#
# Replace ONLY manualArray(). Rewriting the whole class by hand is how you
# end up with NoSuchMethodError at runtime: the real class has fields and
# methods the rest of the app calls, and a hand-written copy will not match.

step "Patching manualArray()"
python3 - "$TARGET" <<'PYEOF' || die "smali patch failed"
import re, sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

m = re.search(r'^\.method[^\n]*\bmanualArray\(\)[^\n]*\n.*?^\.end method\n',
              src, re.S | re.M)
if not m:
    sys.exit("! manualArray() not found - the port's class has changed")

old = m.group(0)

# Preserve the original signature line and any annotation block verbatim, so
# access flags and the generic signature stay exactly as the app expects.
sig = old.split("\n", 1)[0]
ann = ""
a = re.search(r'(\.annotation system Ldalvik/annotation/Signature;.*?\.end annotation\n)',
              old, re.S)
if a:
    ann = "    " + a.group(1).strip() + "\n"
    ann = re.sub(r'^\s*', '    ', a.group(1), flags=re.M)

body = []
body.append(sig)
body.append("    .locals 2")
if ann:
    body.append(ann.rstrip("\n"))
body.append("")
body.append("    new-instance v0, Ljava/util/HashSet;")
body.append("")
body.append("    invoke-direct {v0}, Ljava/util/HashSet;-><init>()V")
for cam in ("0", "1", "2", "3"):
    body.append("")
    body.append('    const-string v1, "%s"' % cam)
    body.append("")
    body.append("    invoke-interface {v0, v1}, Ljava/util/Set;->add(Ljava/lang/Object;)Z")
body.append("")
body.append("    return-object v0")
body.append(".end method")

new = "\n".join(body) + "\n"
src = src[:m.start()] + new + src[m.end():]
open(path, "w", encoding="utf-8").write(src)

print("  replaced manualArray() -> {0,1,2,3}")
PYEOF

# Catch the exact class of typo that broke the previous attempt: a mangled
# opcode assembles into nothing and apktool's error is unhelpful.
if grep -nE 'add-int/(dash|[a-z_]*len)' "$TARGET"; then
  die "corrupted opcode in the patched smali (expected add-int/lit8)"
fi
ok "no malformed opcodes"

# ==================================================================== build

step "Rebuilding"
rm -f "$BUILT"
apktool b -f -o "$BUILT" "$DECODED" > "$WORK/build.log" 2>&1 \
  || { tail -25 "$WORK/build.log" | sed 's/^/  /'; die "apktool b failed (log: $WORK/build.log)"; }
[ -s "$BUILT" ] || die "build produced an empty APK"
unzip -l "$BUILT" >/dev/null 2>&1 || die "built APK is not a valid zip"
ok "built $(du -h "$BUILT" | cut -f1)"

# The rebuild round-trips AndroidManifest.xml. If that loses the permission,
# everything downstream is pointless - check before signing.
if [ "$HAD_PERM" = "1" ]; then
  if [ -f "$SCRIPT_DIR/axml_verify.py" ]; then
    rm -rf "$WORK/mcheck"; mkdir -p "$WORK/mcheck"
    ( cd "$WORK/mcheck" && unzip -o -q "$BUILT" AndroidManifest.xml )
    python3 "$SCRIPT_DIR/axml_verify.py" "$WORK/mcheck/AndroidManifest.xml" \
      android.permission.SYSTEM_CAMERA \
      || die "the rebuild dropped SYSTEM_CAMERA from the manifest"
    ok "SYSTEM_CAMERA survived the rebuild"
  else
    warn "axml_verify.py not found; skipping manifest check"
  fi
fi

# ===================================================================== sign

step "Signing"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -alias k -keyalg RSA -keysize 2048 \
    -validity 10000 -storepass "$KSPASS" -keypass "$KSPASS" \
    -dname "CN=gcam, O=local, C=US" >/dev/null 2>&1 || die "keystore creation failed"
  ok "created $KS"
else
  ok "reusing $KS (keeps the package signature stable)"
fi

rm -f "$SIGNED"
apksigner sign --ks "$KS" --ks-key-alias k \
  --ks-pass "pass:$KSPASS" --key-pass "pass:$KSPASS" \
  --out "$SIGNED" "$BUILT" || die "signing failed"
apksigner verify "$SIGNED" >/dev/null 2>&1 || die "signature verification failed"
ok "signed: $SIGNED"

# =================================================================== deploy

if [ "$DEPLOY" = "1" ]; then
  step "Deploying into the Magisk module"
  as_root "test -d '$APPDIR'" || die "module not found at $APPDIR"
  as_root "cp '$SIGNED' '$APPDIR/base.apk'" || die "could not replace base.apk"
  as_root "chown 0:0 '$APPDIR/base.apk'"
  as_root "chmod 0644 '$APPDIR/base.apk'"
  ok "base.apk replaced (native libs untouched)"
  printf '\n  Reboot, then: su -c "logcat -d | grep GotArray"\n\n'
else
  printf '\n  Install with:\n    %s --deploy\n' "$0"
  printf '  or copy %s into the module by hand.\n\n' "$SIGNED"
fi

[ "$KEEP" = "1" ] || rm -rf "$DECODED" "$BUILT" "$WORK/mcheck"
printf '  Original smali kept at: %s\n\n' "$WORK/eszdman.smali.orig"
