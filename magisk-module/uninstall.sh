#!/system/bin/sh
MODDIR="${0%/*}"
sh "$MODDIR/unlock-cameraserver.sh" revert 2>/dev/null || true
