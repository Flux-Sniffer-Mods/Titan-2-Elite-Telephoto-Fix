#!/system/bin/sh
SKIPUNZIP=0
ui_print "- Titan 2 Elite Telephoto"
[ "$ARCH" = "arm64" ] || abort "!  arm64-only (device is $ARCH)"
if grep -a -q 6410613c /system/bin/cameraserver 2>/dev/null; then
  ui_print "- cameraserver BuildID 6410613c matches"
else
  ui_print "! could not confirm cameraserver BuildID 6410613c"
  ui_print "! offsets assume it; after boot check:"
  ui_print "!   sh \$MODPATH/unlock-cameraserver.sh status"
fi
if [ -f "$MODPATH/gcam-patched.apk" ]; then
  ui_print "- On first boot: unlock + install TeleZoom app + install patched GCam."
  ui_print "  (Installing GCam REPLACES any existing copy of that package.)"
else
  ui_print "- Unlock-only build (no bundled GCam)."
  ui_print "  Build the full module with make-release.sh for the one-flash setup."
fi
ui_print "- Reboot once after flashing."
set_perm_recursive "$MODPATH" 0 0 0755 0755
