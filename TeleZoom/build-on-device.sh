#!/data/data/com.termux/files/usr/bin/bash
# build-on-device.sh — compile TeleZoom.apk in Termux, no Gradle.
# Requires: pkg install -y aapt d8 apksigner openjdk-17   (aapt2 also fine)
# Produces: TeleZoom-signed.apk  (install, then enable in LSPosed, scope=GCam)
set -eu

PKG=com.fluxsniffer.telezoom
SRC=$(find app/src/main/java -name "*.java")
MANIFEST=app/src/main/AndroidManifest.xml
ASSETS=app/src/main/assets
RES=app/src/main/res
OUT=build
rm -rf "$OUT/classes"; mkdir -p "$OUT"

# 0. locate android.jar (platform) + xposed api jar
#    Termux: android.jar ships with 'aapt'/'android-sdk' or grab from any SDK.
ANDROID_JAR="${ANDROID_JAR:-$PREFIX/share/aapt/android.jar}"
[ -f "$ANDROID_JAR" ] || ANDROID_JAR="$(find $PREFIX -name 'android.jar' 2>/dev/null | head -1)"
[ -f "$ANDROID_JAR" ] || { echo "!! android.jar not found. Set ANDROID_JAR=/path/to/android.jar"; exit 1; }

# Xposed API jar — download once (or point XPOSED_JAR at it). Provided at runtime by LSPosed.
XPOSED_JAR="${XPOSED_JAR:-$HOME/xposed-api-82.jar}"
# If the api jar is missing OR unreadable (bad download), build it from bundled stubs.
if [ ! -f "$XPOSED_JAR" ] || ! unzip -l "$XPOSED_JAR" >/dev/null 2>&1; then
  echo "==> Xposed api jar missing/unreadable; compiling from bundled stubs"
  rm -f "$XPOSED_JAR"
  mkdir -p "$OUT/stub-classes"
  javac -source 17 -target 17 -d "$OUT/stub-classes" $(find xposed-stubs -name '*.java')
  ( cd "$OUT/stub-classes" && { jar cf "$XPOSED_JAR" . 2>/dev/null || zip -qr "$XPOSED_JAR" . ; } )
  echo "==> built stub api jar: $XPOSED_JAR"
fi

echo "==> android.jar: $ANDROID_JAR"
echo "==> xposed api : $XPOSED_JAR"

# 1. compile Java -> classes
echo "==> javac"
mkdir -p "$OUT/classes"
javac -source 17 -target 17 \
  -classpath "$ANDROID_JAR:$XPOSED_JAR" \
  -d "$OUT/classes" $SRC

# 2. classes -> dex
echo "==> d8"
d8 --min-api 29 --output "$OUT" \
  $(find "$OUT/classes" -name '*.class')
# d8 emits classes.dex in $OUT

# 3. package resources + manifest -> base apk
echo "==> aapt package"
aapt package -f -M "$MANIFEST" -S "$RES" -A "$ASSETS" \
  -I "$ANDROID_JAR" -F "$OUT/base.apk"

# 4. add dex into the apk
echo "==> add dex"
( cd "$OUT" && aapt add base.apk classes.dex >/dev/null )

# 5. align + sign (debug key; fine for LSPosed modules)
echo "==> zipalign + sign"
KEYSTORE="$HOME/telezoom-debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -v -keystore "$KEYSTORE" -alias telezoom \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass telezoom -keypass telezoom \
    -dname "CN=TeleZoom, OU=Flux-Sniffer-Mods, O=local, C=US"
fi
zipalign -f 4 "$OUT/base.apk" "$OUT/aligned.apk"
apksigner sign --ks "$KEYSTORE" --ks-pass pass:telezoom --key-pass pass:telezoom \
  --out TeleZoom-signed.apk "$OUT/aligned.apk"

echo
echo "==> BUILT: $(pwd)/TeleZoom-signed.apk"
echo "    Install:  su -c 'pm install -r $(pwd)/TeleZoom-signed.apk'  (or tap it)"
echo "    Then: open LSPosed manager -> Modules -> enable 'TeleZoom' -> scope: GCam -> reboot or force-stop GCam"
