#!/data/data/com.termux/files/usr/bin/bash
# quickstart — the short version. The real install is: flash the full module.
cat <<TXT
Titan 2 Elite hidden telephoto — quickstart

  Just flash the release module:

    1. Download titan2-telephoto-FULL.zip from
       https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix/releases
    2. Flash it in Magisk, reboot once.
    3. Open GCam. Zoom in video for tele; tap the TELE button for a tele photo.

  Building it yourself instead? See README.md "Build it yourself":
    bash tools/cache-android-jar.sh
    bash make-full-module.sh /path/to/clean-gcam.apk
TXT
