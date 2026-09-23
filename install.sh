#!/data/data/com.termux/files/usr/bin/bash
#
# install.sh — one-shot setup for the Titan 2 Elite hidden telephoto.
#   Repo: https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix
#
# Does, from a fresh Termux (rooted device):
#   1. installs build deps
#   2. fetches this repo + android.jar + LSPatch
#   3. builds the TeleZoom module APK
#   4. installs the TeleZoom app
#   5. bakes TeleZoom into your installed GCam with LSPatch (backs up the original)
#   6. installs a Magisk module that BOTH reapplies the cameraserver unlock AND
#      keeps the TeleZoom app installed, every boot
#   7. applies the unlock now so you can test immediately
#
# Safe by design: every destructive step is backed up first; re-running is fine.
# Env overrides: ASSUME_YES=1  SKIP_GCAM=1  ANDROID_JAR=/path  LSPATCH_JAR=/path
#                GCAM_PKG=com...  REPO_REF=main  GCAM_APK=/path/to/clean-gcam.apk
#                GCAM_APK_URL=<direct or Google-Drive URL to the clean port APK>
set -u
BLD=$'\033[1m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
say(){ printf '\n%s==> %s%s\n' "$BLD" "$*" "$RST"; }
ok(){  printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn(){ printf '  %s[!]%s  %s\n' "$YLW" "$RST" "$*"; }
die(){ printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*"; exit 1; }
yesno(){ [ "${ASSUME_YES:-0}" = 1 ] && return 0; printf '  %s%s [y/N] %s' "$BLD" "$1" "$RST"; read -r a; case "$a" in y|Y) return 0;; *) return 1;; esac; }

# install an APK, retrying with an uninstall if the signer key differs
# time-boxed root command: never let a root probe hang the script
SROOT_T=15
sroot(){ if command -v timeout >/dev/null 2>&1; then timeout "$SROOT_T" su -c "$*"; else su -c "$*"; fi; }

install_apk(){ # <apk> <pkg> <label>
  local apk="$1" pkg="$2" label="$3" out
  su -c "cp '$apk' $STAGE/_ins.apk && chmod 644 $STAGE/_ins.apk"
  out="$(su -c "pm install -r $STAGE/_ins.apk" 2>&1)"
  case "$out" in
    *Success*) ok "$label installed"; return 0;;
    *INSTALL_FAILED_UPDATE_INCOMPATIBLE*|*signatures*)
      warn "$label: existing copy signed with a different key — reinstalling"
      su -c "pm uninstall $pkg" >/dev/null 2>&1
      out="$(su -c "pm install $STAGE/_ins.apk" 2>&1)"
      case "$out" in *Success*) ok "$label installed (clean)"; return 0;; esac;;
  esac
  warn "$label install failed: $out"; return 1
}

# is this APK already an LSPatch output? (contains an embedded origin apk)
is_patched_apk(){ unzip -l "$1" 2>/dev/null | grep -q "lspatch/origin"; }

# fetch a possibly-Google-Drive URL to $2
fetch_url(){ # <url> <dest>
  case "$1" in
    *drive.google.com*)
      command -v gdown >/dev/null 2>&1 || pip install -U gdown >/dev/null 2>&1
      local id; id="$(printf '%s' "$1" | grep -oE '[-_A-Za-z0-9]{25,}' | head -1)"
      gdown "$id" -O "$2" 2>/dev/null || gdown "https://drive.google.com/uc?id=$id" -O "$2" 2>/dev/null;;
    *) curl -fsSL "$1" -o "$2";;
  esac
  [ -s "$2" ]
}

GCAM_PKG="${GCAM_PKG:-com.google.android.GoogleCameraEngR18F1}"
TZ_PKG="com.fluxsniffer.telezoom"
REPO_REF="${REPO_REF:-main}"
REPO_TGZ="https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix/archive/refs/heads/${REPO_REF}.tar.gz"
ANDROID_JAR_URL="https://dl.google.com/android/repository/platform-35_r01.zip"
WORK="$HOME/.telezoom-build"
STAGE=/data/local/tmp
mkdir -p "$WORK"

# ---------- 0. preflight ----------
say "Preflight"
command -v su >/dev/null 2>&1 || die "no su on PATH — need root"
if ! sroot 'id -u' | grep -q '^0$'; then
  die "root check failed or timed out. Grant Termux root in your superuser app, then re-run."
fi
ok "root ok"
[ "$(uname -m)" = "aarch64" ] || warn "arch is $(uname -m), expected aarch64 (offsets are arm64-only)"
# BuildID: read the world-readable binary directly (no strings/su). Skip with BUILD_ID=.
BID="${BUILD_ID:-}"
if [ -z "$BID" ] && [ -r /system/bin/cameraserver ]; then
  BID="$(grep -a -m1 -oE '6410613c' /system/bin/cameraserver 2>/dev/null || true)"
fi
[ "$BID" = 6410613c ] && ok "cameraserver BuildID 6410613c" || warn "couldn't confirm BuildID 6410613c (continuing; offsets assume it)"
MAGISK="$(sroot 'command -v magisk' 2>/dev/null | tr -d '\r')"; [ -n "$MAGISK" ] || MAGISK=/data/adb/magisk/magisk
sroot "pm path $GCAM_PKG" >/dev/null 2>&1 || { warn "GCam '$GCAM_PKG' not installed — will need GCAM_APK/GCAM_APK_URL, or SKIP_GCAM=1"; }

# ---------- 1. deps ----------
say "Installing Termux packages"
yes | pkg install -y openjdk-17 aapt d8 apksigner zip unzip curl python >/dev/null 2>&1 || warn "pkg install had warnings; continuing"
for t in javac aapt d8 apksigner zip unzip curl python3; do command -v "$t" >/dev/null 2>&1 || die "missing tool after install: $t"; done
ok "build tools present"

# ---------- 2. fetch repo ----------
say "Fetching repo ($REPO_REF)"
if [ -f "$PWD/TeleZoom/build-on-device.sh" ] && [ -d "$PWD/magisk-module" ]; then
  SRC="$PWD"; ok "using the checkout you ran this from: $SRC"
else
  curl -fsSL "$REPO_TGZ" -o "$WORK/repo.tgz" || die "could not download repo tarball"
  rm -rf "$WORK/repo"; mkdir -p "$WORK/repo"
  tar xzf "$WORK/repo.tgz" -C "$WORK/repo" --strip-components=1 || die "repo extract failed"
  SRC="$WORK/repo"; ok "extracted to $SRC"
fi

# ---------- 3. android.jar ----------
say "android.jar (for the build)"
AJ="${ANDROID_JAR:-$WORK/android.jar}"
if [ -f "$AJ" ]; then ok "using: $AJ"
else
  # Prefer an android.jar already on this device (stable cache, build cache, SDK)
  found=""
  for c in "$HOME/.telezoom-cache/android.jar" \
           "$WORK/android.jar" \
           "$HOME/.telezoom-build/android.jar" \
           $HOME/android-sdk/platforms/android-*/android.jar \
           $PREFIX/share/aapt/android.jar; do
    [ -f "$c" ] && { found="$c"; break; }
  done
  if [ -z "$found" ]; then
    found="$(find "$HOME" $PREFIX/share -maxdepth 6 -name android.jar 2>/dev/null | head -1)"
    if [ -z "$found" ]; then
      found="$(su -c "find /sdcard /storage/emulated/0 -maxdepth 6 -name android.jar" 2>/dev/null | head -1)"
    fi
  fi
  if [ -n "$found" ]; then
    cp "$found" "$AJ" 2>/dev/null || su -c "cp '$found' $AJ"; su -c "chown $(id -u):$(id -g) $AJ" 2>/dev/null || true
    ok "sourced android.jar from device: $found"
  else
    warn "no android.jar on device — downloading"
    curl -fsSL "$ANDROID_JAR_URL" -o "$WORK/platform.zip" || die "android.jar download failed (set ANDROID_JAR=/path)"
    ( cd "$WORK" && unzip -o -j platform.zip '*/android.jar' -d "$WORK" >/dev/null ) || die "could not extract android.jar"
    [ -f "$AJ" ] || die "android.jar not found after extract"
    ok "downloaded: $AJ"
  fi
  # keep a wipe-proof copy so future runs never re-download
  mkdir -p "$HOME/.telezoom-cache" 2>/dev/null && cp -f "$AJ" "$HOME/.telezoom-cache/android.jar" 2>/dev/null && ok "cached to ~/.telezoom-cache/android.jar"
fi

# ---------- 4. build TeleZoom ----------
say "Building TeleZoom.apk (bundled Xposed stubs; no api jar needed)"
cd "$SRC/TeleZoom" || die "TeleZoom source missing"
rm -rf build TeleZoom-signed.apk
ANDROID_JAR="$AJ" XPOSED_JAR="$HOME/xposed-api-82.jar" bash build-on-device.sh >"$WORK/build.log" 2>&1 \
  || { tail -20 "$WORK/build.log"; die "TeleZoom build failed (full log: $WORK/build.log)"; }
[ -f TeleZoom-signed.apk ] || die "build produced no APK"
APK="$SRC/TeleZoom/TeleZoom-signed.apk"
ok "built $(basename "$APK")"

# ---------- 5. install the TeleZoom app ----------
say "Installing the TeleZoom app"
install_apk "$APK" "$TZ_PKG" "TeleZoom app" \
  || warn "TeleZoom app install failed — the boot module will retry it"

# ---------- 6. bake into GCam via LSPatch ----------
if [ "${SKIP_GCAM:-0}" = 1 ]; then
  warn "SKIP_GCAM set — leaving GCam unpatched. Enable TeleZoom in LSPosed (scope: GCam) instead."
else
  say "Baking TeleZoom into GCam ($GCAM_PKG)"
  # 6a. LSPatch jar
  LSP="${LSPATCH_JAR:-$WORK/lspatch.jar}"
  if [ -f "$LSP" ]; then ok "LSPatch cached: $LSP"
  else
    URL="$(curl -fsSL https://api.github.com/repos/JingMatrix/LSPatch/releases/latest 2>/dev/null | grep -o 'https://[^"]*\.jar' | head -1)"
    [ -z "$URL" ] && URL="$(curl -fsSL https://api.github.com/repos/LSPosed/LSPatch/releases/latest 2>/dev/null | grep -o 'https://[^"]*\.jar' | head -1)"
    [ -n "$URL" ] || die "could not find an LSPatch release jar (set LSPATCH_JAR=/path)"
    curl -fsSL "$URL" -o "$LSP" || die "LSPatch download failed"
    ok "fetched LSPatch: $(basename "$URL")"
  fi
  # 6b. obtain a CLEAN original GCam APK (never patch an already-patched one)
  ORIG="$STAGE/gcam-original.apk"
  CLEAN="$WORK/gcam-original.apk"
  su -c "rm -rf $STAGE/gcam_prefs_bak; cp -a /data/data/$GCAM_PKG/shared_prefs $STAGE/gcam_prefs_bak" 2>/dev/null || warn "no GCam shared_prefs to back up (first run?)"
  installed="$(su -c "pm path $GCAM_PKG | head -1 | sed 's/^package://'" 2>/dev/null)"
  got_clean=0
  # prefer an explicit clean APK the user gave us
  if [ -n "${GCAM_APK:-}" ] && [ -f "$GCAM_APK" ] && ! is_patched_apk "$GCAM_APK"; then
    cp "$GCAM_APK" "$CLEAN"; got_clean=1; ok "using GCAM_APK: $GCAM_APK"
  fi
  # else a clean backup from a previous run
  if [ "$got_clean" = 0 ] && [ -f "$STAGE/gcam-original.apk" ] && ! is_patched_apk "$STAGE/gcam-original.apk"; then
    su -c "cp $STAGE/gcam-original.apk $CLEAN"; su -c "chown $(id -u):$(id -g) $CLEAN" 2>/dev/null || true; got_clean=1; ok "using clean backup $STAGE/gcam-original.apk"
  fi
  # else the installed APK, but ONLY if it is not itself LSPatched
  if [ "$got_clean" = 0 ] && [ -n "$installed" ]; then
    su -c "cp $installed $CLEAN"; su -c "chown $(id -u):$(id -g) $CLEAN" 2>/dev/null || true
    if is_patched_apk "$CLEAN"; then
      warn "the installed GCam is already LSPatched — cannot re-patch it."
      rm -f "$CLEAN"
    else got_clean=1; ok "using installed GCam (clean)"; fi
  fi
  # else download one
  if [ "$got_clean" = 0 ] && [ -n "${GCAM_APK_URL:-}" ]; then
    say "Downloading a clean GCam APK"
    if fetch_url "$GCAM_APK_URL" "$CLEAN" && ! is_patched_apk "$CLEAN"; then got_clean=1; ok "downloaded clean GCam"; else warn "download failed or file was already patched"; fi
  fi
  [ "$got_clean" = 1 ] || die "no clean GCam APK. Provide one with GCAM_APK=/path or GCAM_APK_URL=... (the installed copy is already patched)."
  # verify it is the expected package
  pkgname="$(aapt dump badging "$CLEAN" 2>/dev/null | sed -n "s/.*package: name='\([^']*\)'.*/\1/p")"
  [ "$pkgname" = "$GCAM_PKG" ] || warn "clean APK package is '$pkgname', expected '$GCAM_PKG'"
  su -c "cp $CLEAN $ORIG && chmod 644 $ORIG"
  ok "clean original ready -> $ORIG (+ $CLEAN)"
  # 6c. patch
  cp "$APK" "$WORK/telezoom-module.apk"
  rm -rf "$WORK/lspatched"
  java -jar "$LSP" -f -l 2 -m "$WORK/telezoom-module.apk" -o "$WORK/lspatched" "$CLEAN" >"$WORK/lspatch.log" 2>&1 \
    || { tail -20 "$WORK/lspatch.log"; die "LSPatch failed (log: $WORK/lspatch.log)"; }
  OUT="$(ls "$WORK"/lspatched/*.apk 2>/dev/null | head -1)"; [ -n "$OUT" ] || die "LSPatch produced no APK"
  ok "patched: $(basename "$OUT")"
  # 6d. install (in place if signatures match, else uninstall+reinstall+restore prefs)
  su -c "cp '$OUT' $STAGE/gcam-lspatched.apk && chmod 644 $STAGE/gcam-lspatched.apk"
  if su -c "pm install -r $STAGE/gcam-lspatched.apk" 2>/dev/null | grep -q Success; then
    ok "patched GCam installed in place (settings kept)"
  else
    warn "in-place update refused (signature change) — this REPLACES GCam."
    if yesno "Uninstall GCam and install the patched one?"; then
      su -c "pm uninstall $GCAM_PKG; pm install $STAGE/gcam-lspatched.apk" | grep -q Success || die "patched GCam install failed"
      su -c "am start -n $GCAM_PKG/com.android.camera.CameraLauncher"; sleep 6
      su -c "am force-stop $GCAM_PKG; U=\$(stat -c %u /data/data/$GCAM_PKG); rm -rf /data/data/$GCAM_PKG/shared_prefs; cp -a $STAGE/gcam_prefs_bak /data/data/$GCAM_PKG/shared_prefs 2>/dev/null; chown -R \$U:\$U /data/data/$GCAM_PKG/shared_prefs 2>/dev/null; restorecon -R /data/data/$GCAM_PKG/shared_prefs 2>/dev/null" || true
      ok "patched GCam installed; settings restored"
    else
      warn "left GCam unpatched. Original backup is at $ORIG."
    fi
  fi
  su -c "pm list packages org.lsposed.manager >/dev/null 2>&1" && warn "LSPosed is installed: make sure GCam is NOT in TeleZoom's LSPosed scope, or the hooks run twice."
fi

# ---------- 7. Magisk module (unlock at boot + keep the app installed) ----------
say "Building + installing the boot module (unlock + app-refresh)"
MOD="$WORK/module"; rm -rf "$MOD"; mkdir -p "$MOD"
cp -a "$SRC/magisk-module/." "$MOD/"
cp "$APK" "$MOD/telezoom.apk"          # <- the module now carries the app and installs it at boot
MZIP="$WORK/titan2-telephoto-module.zip"
( cd "$MOD" && rm -f "$MZIP" && zip -qr -X "$MZIP" . )
if su -c "$MAGISK --install-module $MZIP" 2>/dev/null; then
  ok "module installed via magisk (reapplies unlock + refreshes the app each boot)"
else
  warn "magisk --install-module not available; installing module files directly"
  M=/data/adb/modules/titan2_tele_unlock
  su -c "rm -rf $M && mkdir -p $M && cp -a $MOD/. $M/ && chmod -R 0755 $M" && ok "module placed at $M (active next boot)" \
    || warn "direct module install failed — flash $MZIP from the Magisk app instead"
fi
ok "module zip also saved at: $MZIP"

# ---------- 8. apply unlock now ----------
say "Applying the cameraserver unlock for THIS boot"
ASSUME_YES=1 bash "$SRC/reject-bypass.sh" --apply >"$WORK/unlock.log" 2>&1
if bash "$SRC/reject-bypass.sh" --status | grep -q 'patched=False'; then
  warn "some unlock sites not patched — see $WORK/unlock.log and reject-bypass.sh --status"
else
  ok "unlock live (all four sites)"
fi

# ---------- done ----------
say "Done"
cat <<TXT
  ${GRN}Telephoto is set up.${RST}

  Test now:
    - GCam VIDEO: zoom past ~2x -> 6.8mm tele engages (finger-test the lens).
    - GCam PHOTO: tap the round ${BLD}TELE${RST} button -> shoot -> saved to DCIM/Camera at 6.8mm.

  Verify unlock:   bash "$SRC/reject-bypass.sh" --status
  Revert GCam:     su -c "pm uninstall $GCAM_PKG && pm install $STAGE/gcam-original.apk"
  Logs:            $WORK/{build,lspatch,unlock}.log

  The boot module reapplies the unlock and keeps the TeleZoom app installed on
  every reboot, so nothing here needs re-running.
TXT
