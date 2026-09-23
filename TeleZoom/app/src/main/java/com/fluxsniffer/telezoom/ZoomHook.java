package com.fluxsniffer.telezoom;

import android.graphics.Rect;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;

import java.util.Collections;
import java.util.Set;
import java.util.WeakHashMap;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam;

/**
 * TeleZoom — Titan 2 Elite optical telephoto via SCALER_CROP_REGION shaping.
 *
 * DISCOVERED (from live logs): this GCam port zooms by setting
 * android.scaler.cropRegion (SCALER_CROP_REGION) on the capture request, NOT
 * CONTROL_ZOOM_RATIO. It ramps the crop continuously from full-sensor down to a
 * tiny centered rect, and the MediaTek SAT HAL treats that as pure digital zoom,
 * so the 6.8mm optical glass never engages.
 *
 * Active array observed as ~4096 x 3072 (crop rects stay centered on ~2048,1536).
 * The optical crossover is ~3.4x. To force the HAL's tele switch we SNAP the crop
 * to a clean, centered rectangle at the crossover fraction once GCam crops past it,
 * instead of letting the crop ramp smoothly. Above the crossover we hold the crop
 * at the tele framing (the optical lens then provides the reach); we do not crop
 * tighter than the tele sweet spot, which is where image quality is best.
 *
 * v2 — LOGICAL-DEVICE REDIRECT. Live dumpsys showed GCam only ever opens
 * device 0 (physical main sensor), while the stock camera opens device 3
 * (LOGICAL_MULTI_CAMERA [0 2]) whenever the tele is active. The SAT lens switch
 * lives on the logical device, so no crop on device 0 can ever reach the 6.8mm
 * glass. We now rewrite GCam's openCamera("0") -> "3" (REDIRECT_FROM/TO) and keep
 * the crop snap. Front camera ("1") is never touched.
 *
 * v3 — RATIO MODE: crop snap on cam3 did NOT switch lenses (finger test).
 * GCam's crop zoom is now translated to CONTROL_ZOOM_RATIO (+ full-FOV crop),
 * the same key stock drives, so the SAT HAL selects the tele itself.
 *
 * v4 — HIDE_RAW: stock runs the tele with no RAW stream; GCam photo mode
 * configured RAW16 4096x3072, pinning the main sensor. RAW is hidden from GCam's
 * view of the back camera so it uses its YUV photo path.
 *
 * v5 — HIDE_RAW returned null for RAW sizes and GCam NPE'd (OneCamera failed
 * to open). Now returns an empty array, and logs null characteristic reads plus
 * the caller stack of the first RAW size query.
 *
 * v6 — HIDE_RAW off (photo pipeline needs RAW10 -> photo stays on main lens);
 * zoom ratio reset to 1.0 when GCam clears the crop (fixes "stuck on tele").
 *
 * v7-diag — HIDE_RAW back ON + hooks GCam's OneCamera failure handlers
 * (exh/ghh .a(Throwable)) to log the full NPE stack.
 *
 * v10 — EXPERIMENT: PHOTO_NO_RAW swaps photo mode's RAW streams (hdn.get())
 * for YUV_LARGE, the stream IMAGE_INTENT shoots from on the tele.
 *
 * v11 — TELE button on GCam's main screen opens TeleShot; when GCam is launched by
 * TeleShot (output URI authority) the zoom ratio is held >= 2.5x (auto-tele).
 * PHOTO_NO_RAW off: photo mode's capture graph is RAW-bound by its DI wiring.
 *
 * v12 — TeleShot mode scales GCam's zoom by 2.5 (UI "1x" = tele framing) and
 * auto-presses Done on the intent review screen; TeleShot loops shot after shot.
 *
 * v13 — FONTFIX for LSPatch builds (FontsContract.sContext null -> fonts thread
 * crash / black photo preview). Auto-Done off.
 *
 * This only rewrites arguments inside GCam's own process. It never touches
 * cameraserver.
 */
public class ZoomHook implements IXposedHookLoadPackage {

    private static final String GCAM_PKG = "com.google.android.GoogleCameraEngR18F1";
    private static final String TAG = "TeleZoom";

    // Set true to keep logging crop rects (for tuning); false to quiet down.
    private static final boolean DIAG = true;

    // Active sensor array (full-FOV crop). Derived from logs: crops centre on
    // (~2048, ~1536) => array 4096 x 3072. If a different array shows up at 1x,
    // we auto-learn it below (largest crop width seen wins).
    private static volatile int ARRAY_W = 4096;
    private static volatile int ARRAY_H = 3072;

    // Optical crossover ~3.4x. Crop fraction = 1/3.4 ~= 0.294 of the array.
    // Snap to this framing to trigger the tele switch. Tune 0.25..0.33 if needed.
    private static final float TELE_FRAC = 0.294f;

    // Only start shaping once GCam has cropped in past this (i.e. user is zooming
    // toward tele). Below this we leave the crop alone => normal wide/1x behaviour.
    private static final float TRIGGER_FRAC = 0.55f; // crop width < 0.55*array => engage

    // v2: open the logical multi-camera instead of the physical main sensor.
    // Set REDIRECT=false to get the v1 (device 0) behaviour back.
    private static final boolean REDIRECT = true;
    private static final String REDIRECT_FROM = "0";
    private static final String REDIRECT_TO   = "3";

    // v3: RATIO MODE. The crop snap alone does not switch lenses, even on cam3.
    // Instead, translate GCam's crop zoom into CONTROL_ZOOM_RATIO (the key stock
    // uses) and hand the HAL a full-FOV crop of the same aspect, so the SAT HAL
    // chooses the lens itself at its own crossover. Zoom level is preserved
    // exactly (no clamp). Only applied while cam REDIRECT_TO is open.
    // RATIO_MODE=false => v2 crop-snap behaviour.
    private static final boolean RATIO_MODE = true;
    private static final float RATIO_MIN = 1.0f;   // cam3 zoomRatioRange lower bound
    private static final float RATIO_MAX = 20.0f;  // cam3 zoomRatioRange upper bound
    // Optional: force at least this ratio once zoom passes RATIO_BOOST_FROM, in case
    // the HAL wants a clear margin past its crossover. 0 = off (pure translation).
    private static final float RATIO_BOOST_FROM = 0.0f;
    private static final float RATIO_BOOST_TO   = 3.5f;

    // v4: HIDE_RAW. Stock (com.mediatek.camera) runs the tele with NO RAW stream;
    // GCam photo mode configures a 4096x3072 RAW16 (0x20) stream, and the tele
    // has no RAW, so the SAT HAL stays on the main sensor. We hide RAW from GCam's
    // view of the back camera (ids 0 and 3) so it picks its YUV photo path.
    private static final boolean HIDE_RAW = false; // v8: OFF (photo pipeline needs RAW10). GCam photo pipeline
    // requires RAW10 on the main lens (NPE with RAW hidden), so photo stays on main.
    private static final int CAP_RAW = 3; // REQUEST_AVAILABLE_CAPABILITIES_RAW
    private static final int[] RAW_FMTS = {0x20 /*RAW_SENSOR*/, 0x24 /*RAW_PRIVATE*/,
            0x25 /*RAW10*/, 0x26 /*RAW12*/};
    private static final Set<Object> BACK_CHARS =
            Collections.synchronizedSet(Collections.newSetFromMap(new WeakHashMap<Object, Boolean>()));
    private static final Set<Object> BACK_MAPS =
            Collections.synchronizedSet(Collections.newSetFromMap(new WeakHashMap<Object, Boolean>()));
    private static volatile boolean loggedCaps = false, loggedFmts = false, loggedRawQuery = false;
    // v5: log (once per key) any back-camera characteristic GCam reads that is null.
    private static final Set<String> NULL_KEYS_LOGGED =
            Collections.synchronizedSet(new java.util.HashSet<String>());

    // v10 EXPERIMENT: PHOTO mode on cam3 without RAW. hdn.get() builds GCam's stream
    // map (jadx, this build): photo = VIEWFINDER + RAW_HDRPLUS (+YUV_ANALYSIS...).
    // IMAGE_INTENT (hdn case 7) = VIEWFINDER + YUV_LARGE and shoots on the tele.
    // Swap photo's RAW streams for YUV_LARGE (hdn field "f" = the YUV_LARGE provider).
    private static final boolean PHOTO_NO_RAW = false; // v11: OFF — photo capture graph is RAW-bound (Dagger wiring)
    private static final String HDN_CLASS = "hdn";
    private static final String HDR_ENUM = "hdr";
    private static final String HDN_JRL_FIELD = "a";       // giv -> jrl mode
    private static final String HDN_YUV_LARGE_FIELD = "f"; // qkgVar5 -> YUV_LARGE lnz
    private static final String[] RAW_STREAM_KEYS = {"RAW_HDRPLUS", "RAW_WIDE", "RAW_TELE", "RAW_ULTRAWIDE"};

    // v11: TELE button inside GCam + auto-tele for TeleShot launches.
    private static final boolean TELE_BUTTON = true;
    private static final String TELESHOT_AUTH = "com.fluxsniffer.telezoom.shot";
    private static final String TELESHOT_PKG = "com.fluxsniffer.telezoom";
    private static final String TELESHOT_CLS = "com.fluxsniffer.telezoom.TeleShot";
    // v12: in TeleShot mode GCam's zoom is SCALED by this (its "1x" = tele framing,
    // "2" = 2x on the tele, pinch works), instead of v11's clamp that left the UI at 1x.
    private static final float TELESHOT_BASE_RATIO = 2.5f;
    // v12: auto-confirm GCam's intent review screen (uiautomator dump, this build):
    // retake_button (content-desc "Retake") + shutter_button (content-desc "Done").
    private static final boolean TELESHOT_AUTO_DONE = false; // user: confirm manually
    private static final String GCAM_RETAKE_ID = "retake_button";
    private static final String GCAM_SHUTTER_ID = "shutter_button";
    private static final String BTN_TAG = "telezoom_teleshot_btn";
    private static volatile boolean teleShotActive = false;
    private static volatile boolean loggedActivities = false;

    private static volatile String openId = null;          // last id actually opened
    private static volatile float lastLoggedRatio = -1f;
    private static final ThreadLocal<Boolean> SELF = new ThreadLocal<>();

    @Override
    public void handleLoadPackage(final LoadPackageParam lpparam) {
        if (!GCAM_PKG.equals(lpparam.packageName)) return;
        XposedBridge.log(TAG + ": attached to " + lpparam.packageName);

        if (REDIRECT) installOpenRedirect();
        if (HIDE_RAW) installHideRaw();
        installFailureTrace(lpparam.classLoader);
        if (PHOTO_NO_RAW) installPhotoNoRaw(lpparam.classLoader);
        installActivityHooks();
        installFontsContextFix();

        try {
            XposedHelpers.findAndHookMethod(
                CaptureRequest.Builder.class, "set",
                CaptureRequest.Key.class, Object.class,
                new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        try {
                            CaptureRequest.Key<?> key = (CaptureRequest.Key<?>) param.args[0];
                            if (key == null) return;
                            if (CaptureRequest.CONTROL_ZOOM_RATIO.getName().equals(key.getName())) {
                                if (!Boolean.TRUE.equals(SELF.get()) && DIAG)
                                    XposedBridge.log(TAG + ": GCam set zoomRatio=" + param.args[1]);
                                return;
                            }
                            if (!CaptureRequest.SCALER_CROP_REGION.getName().equals(key.getName())) return;

                            Object val = param.args[1];
                            if (!(val instanceof Rect)) {
                                // v6: GCam clears the crop at 1x. Reset the ratio we set
                                // earlier, or it sticks on the builder (=> stuck on tele).
                                if (RATIO_MODE && REDIRECT_TO.equals(openId)
                                        && !Boolean.TRUE.equals(SELF.get())) {
                                    CaptureRequest.Builder b0 = (CaptureRequest.Builder) param.thisObject;
                                    SELF.set(Boolean.TRUE);
                                    try {
                                        b0.set(CaptureRequest.CONTROL_ZOOM_RATIO,
                                                teleShotActive ? TELESHOT_BASE_RATIO : 1.0f);
                                    } finally {
                                        SELF.set(Boolean.FALSE);
                                    }
                                    if (DIAG && lastLoggedRatio != 1.0f) {
                                        lastLoggedRatio = 1.0f;
                                        XposedBridge.log(TAG + ": RESET zoomRatio=1.0 (crop cleared: " + val + ")");
                                    }
                                }
                                return;
                            }
                            Rect r = (Rect) val;

                            int cw = r.width();
                            int ch = r.height();
                            if (cw <= 0 || ch <= 0) return;

                            // Auto-learn the active array from the largest crop we ever see
                            // (GCam sends full-array at 1x).
                            if (cw > ARRAY_W) ARRAY_W = cw;
                            if (ch > ARRAY_H) ARRAY_H = ch;

                            float fracW = (float) cw / (float) ARRAY_W;

                            if (RATIO_MODE) {
                                if (Boolean.TRUE.equals(SELF.get())) return;
                                if (!REDIRECT_TO.equals(openId)) return; // front cam etc: untouched
                                float ratio = (float) ARRAY_W / (float) cw;
                                if (RATIO_BOOST_FROM > 0f && ratio >= RATIO_BOOST_FROM
                                        && ratio < RATIO_BOOST_TO) ratio = RATIO_BOOST_TO;
                                if (teleShotActive) ratio = ratio * TELESHOT_BASE_RATIO;
                                if (ratio < RATIO_MIN) ratio = RATIO_MIN;
                                if (ratio > RATIO_MAX) ratio = RATIO_MAX;

                                // Same aspect as GCam's crop, scaled back up to full FOV,
                                // centered. In zoom-ratio mode the HAL applies the ratio.
                                float k = (float) ARRAY_W / (float) cw;
                                int fw = Math.min(ARRAY_W, Math.round(cw * k));
                                int fh = Math.min(ARRAY_H, Math.round(ch * k));
                                int fl = (ARRAY_W - fw) / 2;
                                int ft = (ARRAY_H - fh) / 2;
                                Rect full = new Rect(fl, ft, fl + fw, ft + fh);
                                param.args[1] = full;

                                CaptureRequest.Builder b = (CaptureRequest.Builder) param.thisObject;
                                SELF.set(Boolean.TRUE);
                                try {
                                    b.set(CaptureRequest.CONTROL_ZOOM_RATIO, ratio);
                                } finally {
                                    SELF.set(Boolean.FALSE);
                                }
                                if (DIAG && Math.abs(ratio - lastLoggedRatio) > 0.05f) {
                                    lastLoggedRatio = ratio;
                                    XposedBridge.log(TAG + ": RATIO crop " + cw + "x" + ch
                                            + " -> zoomRatio=" + ratio + " crop=" + full.toShortString()
                                            + " (cam" + openId + ")");
                                }
                                return;
                            }

                            // Not zooming in far enough yet -> leave crop untouched.
                            if (fracW >= TRIGGER_FRAC) {
                                if (DIAG) XposedBridge.log(TAG + ": passthru crop " + cw + "x" + ch
                                        + " frac=" + fracW);
                                return;
                            }

                            // Snap to the tele crossover framing: centered rect at TELE_FRAC.
                            int cx = r.centerX();
                            int cy = r.centerY();
                            int newW = Math.round(ARRAY_W * TELE_FRAC);
                            int newH = Math.round(ARRAY_H * TELE_FRAC);

                            int left = cx - newW / 2;
                            int top  = cy - newH / 2;
                            // clamp inside the array
                            if (left < 0) left = 0;
                            if (top  < 0) top  = 0;
                            if (left + newW > ARRAY_W) left = ARRAY_W - newW;
                            if (top  + newH > ARRAY_H) top  = ARRAY_H - newH;

                            Rect snapped = new Rect(left, top, left + newW, top + newH);
                            param.args[1] = snapped;

                            if (DIAG) XposedBridge.log(TAG + ": SNAP crop " + cw + "x" + ch
                                    + " -> " + newW + "x" + newH + " " + snapped.toShortString()
                                    + " (tele switch, array " + ARRAY_W + "x" + ARRAY_H + ")");
                        } catch (Throwable t) {
                            XposedBridge.log(TAG + ": hook error (ignored): " + t);
                        }
                    }
                }
            );
            XposedBridge.log(TAG + ": SCALER_CROP_REGION hook installed v6 (mode="
                    + (RATIO_MODE ? "ratio" : "snap") + ", tele_frac=" + TELE_FRAC
                    + ", trigger=" + TRIGGER_FRAC + ")");
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": failed to install crop hook: " + t);
        }
    }

    /** Rewrites CameraManager.openCamera(id, ...) "0" -> "3" (all public overloads). */
    private static void installOpenRedirect() {
        try {
            XC_MethodHook redirect = new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    try {
                        if (param.args == null || param.args.length == 0) return;
                        if (!(param.args[0] instanceof String)) return;
                        String id = (String) param.args[0];
                        if (!REDIRECT_FROM.equals(id)) {
                            openId = id;
                            XposedBridge.log(TAG + ": openCamera(" + id + ") untouched");
                            return;
                        }
                        param.args[0] = REDIRECT_TO;
                        openId = REDIRECT_TO;
                        XposedBridge.log(TAG + ": REDIRECT openCamera(" + id + ") -> ("
                                + REDIRECT_TO + ")");
                        logTarget((CameraManager) param.thisObject);
                    } catch (Throwable t) {
                        XposedBridge.log(TAG + ": redirect error (ignored): " + t);
                    }
                }
            };
            int n = XposedBridge.hookAllMethods(CameraManager.class, "openCamera", redirect).size();
            XposedBridge.log(TAG + ": openCamera redirect installed (" + REDIRECT_FROM + "->"
                    + REDIRECT_TO + ", " + n + " overloads)");
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": failed to install open redirect: " + t);
        }
    }

    /** One-shot diag: what does the redirect target look like? */
    private static volatile boolean loggedTarget = false;
    private static void logTarget(CameraManager cm) {
        if (loggedTarget || cm == null) return;
        loggedTarget = true;
        try {
            CameraCharacteristics c = cm.getCameraCharacteristics(REDIRECT_TO);
            Rect aa = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
            Object zr = null;
            try { zr = c.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE); } catch (Throwable ignored) {}
            XposedBridge.log(TAG + ": target cam" + REDIRECT_TO + " activeArray="
                    + (aa == null ? "null" : aa.toShortString()) + " zoomRatioRange=" + zr);
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": target diag failed: " + t);
        }
    }

    private static boolean isRawFmt(int f) {
        for (int r : RAW_FMTS) if (r == f) return true;
        return false;
    }

    /** Hide RAW capability + RAW output formats on the back camera (ids 0/3). */
    private static void installHideRaw() {
        try {
            // 1. Tag the characteristics objects GCam gets for the back camera.
            XposedHelpers.findAndHookMethod(CameraManager.class, "getCameraCharacteristics",
                String.class, new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        String id = (String) param.args[0];
                        Object res = param.getResult();
                        if (res != null && (REDIRECT_FROM.equals(id) || REDIRECT_TO.equals(id)))
                            BACK_CHARS.add(res);
                    }
                });

            // 2. Filter capabilities; tag the stream map.
            XposedHelpers.findAndHookMethod(CameraCharacteristics.class, "get",
                CameraCharacteristics.Key.class, new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        try {
                            if (!BACK_CHARS.contains(param.thisObject)) return;
                            CameraCharacteristics.Key<?> k = (CameraCharacteristics.Key<?>) param.args[0];
                            if (k == null) return;
                            String n = k.getName();
                            Object res = param.getResult();
                            if (res == null && DIAG && NULL_KEYS_LOGGED.add(n))
                                XposedBridge.log(TAG + ": NULL char key read by GCam: " + n);
                            if ("android.request.availableCapabilities".equals(n) && res instanceof int[]) {
                                int[] caps = (int[]) res;
                                int keep = 0;
                                for (int c : caps) if (c != CAP_RAW) keep++;
                                if (keep == caps.length) return;
                                int[] out = new int[keep];
                                int i = 0;
                                for (int c : caps) if (c != CAP_RAW) out[i++] = c;
                                param.setResult(out);
                                if (!loggedCaps) { loggedCaps = true;
                                    XposedBridge.log(TAG + ": HIDE_RAW removed RAW capability"); }
                            } else if ("android.scaler.streamConfigurationMap".equals(n) && res != null) {
                                BACK_MAPS.add(res);
                            }
                        } catch (Throwable t) {
                            XposedBridge.log(TAG + ": hide-raw caps error (ignored): " + t);
                        }
                    }
                });

            // 3. Make RAW formats look unsupported on the tagged stream map.
            XposedHelpers.findAndHookMethod(StreamConfigurationMap.class, "getOutputFormats",
                new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        if (!BACK_MAPS.contains(param.thisObject)) return;
                        Object res = param.getResult();
                        if (!(res instanceof int[])) return;
                        int[] f = (int[]) res;
                        int keep = 0;
                        for (int x : f) if (!isRawFmt(x)) keep++;
                        if (keep == f.length) return;
                        int[] out = new int[keep];
                        int i = 0;
                        for (int x : f) if (!isRawFmt(x)) out[i++] = x;
                        param.setResult(out);
                        if (!loggedFmts) { loggedFmts = true;
                            XposedBridge.log(TAG + ": HIDE_RAW removed RAW output formats"); }
                    }
                });
            // v5: EMPTY array, not null — GCam NPEs on null (getClass() null-check).
            XC_MethodHook nullForRaw = new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (!BACK_MAPS.contains(param.thisObject)) return;
                    if (param.args[0] instanceof Integer && isRawFmt((Integer) param.args[0])) {
                        param.setResult(new android.util.Size[0]);
                        if (!loggedRawQuery) { loggedRawQuery = true;
                            XposedBridge.log(TAG + ": HIDE_RAW answered RAW size query (fmt 0x"
                                    + Integer.toHexString((Integer) param.args[0]) + ") with empty; caller:");
                            XposedBridge.log(new Throwable("TeleZoom RAW size query"));
                        }
                    }
                }
            };
            XposedHelpers.findAndHookMethod(StreamConfigurationMap.class, "getOutputSizes",
                int.class, nullForRaw);
            XposedHelpers.findAndHookMethod(StreamConfigurationMap.class, "getHighResolutionOutputSizes",
                int.class, nullForRaw);
            XposedHelpers.findAndHookMethod(StreamConfigurationMap.class, "isOutputSupportedFor",
                int.class, new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        if (!BACK_MAPS.contains(param.thisObject)) return;
                        if (isRawFmt((Integer) param.args[0])) param.setResult(Boolean.FALSE);
                    }
                });
            XposedBridge.log(TAG + ": HIDE_RAW v5 hooks installed (ids " + REDIRECT_FROM + "/" + REDIRECT_TO + ")");
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": failed to install HIDE_RAW: " + t);
        }
    }

    // v7: GCam's OneCamera failure handlers (jadx, this exact build). Their logger
    // only prints a summary; dump the real Throwable with every "Caused by".
    private static final String[] FAIL_CLASSES = {"exh", "ghh"};

    private static void installFailureTrace(ClassLoader cl) {
        for (final String cls : FAIL_CLASSES) {
            try {
                XposedHelpers.findAndHookMethod(cls, cl, "a", Throwable.class, new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        Throwable th = (Throwable) param.args[0];
                        XposedBridge.log(TAG + ": FAILTRACE " + cls + ".a() got: " + th);
                        int depth = 0;
                        for (Throwable t = th; t != null && depth < 6; t = t.getCause(), depth++) {
                            XposedBridge.log(TAG + ": FAILTRACE [" + depth + "] " + t);
                            StackTraceElement[] st = t.getStackTrace();
                            for (int i = 0; i < st.length && i < 25; i++)
                                XposedBridge.log(TAG + ": FAILTRACE   at " + st[i]);
                        }
                    }
                });
                XposedBridge.log(TAG + ": failure trace hooked on " + cls);
            } catch (Throwable t) {
                XposedBridge.log(TAG + ": could not hook " + cls + ".a(Throwable): " + t);
            }
        }
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private static void installPhotoNoRaw(final ClassLoader cl) {
        try {
            final Class hdrCls = cl.loadClass(HDR_ENUM);
            XposedHelpers.findAndHookMethod(HDN_CLASS, cl, "get", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        if (!REDIRECT_TO.equals(openId)) return;
                        Object res = param.getResult();
                        if (!(res instanceof java.util.Map)) return;
                        java.util.Map map = (java.util.Map) res;
                        Object mode = XposedHelpers.callMethod(
                                XposedHelpers.getObjectField(param.thisObject, HDN_JRL_FIELD), "get");
                        String modeName = String.valueOf(mode);
                        StringBuilder removed = new StringBuilder();
                        if (!"PHOTO".equals(modeName)) {
                            XposedBridge.log(TAG + ": PHOTO_NO_RAW skip mode=" + modeName + " streams=" + map.keySet());
                            return;
                        }
                        for (String k : RAW_STREAM_KEYS) {
                            Object key = Enum.valueOf(hdrCls, k);
                            if (map.remove(key) != null) removed.append(k).append(' ');
                        }
                        Object yuvKey = Enum.valueOf(hdrCls, "YUV_LARGE");
                        String added = "already present";
                        if (!map.containsKey(yuvKey)) {
                            Object prov = XposedHelpers.getObjectField(param.thisObject, HDN_YUV_LARGE_FIELD);
                            Object lnz = XposedHelpers.callMethod(prov, "get");
                            if (lnz != null) { map.put(yuvKey, lnz); added = "added"; }
                            else added = "provider returned null";
                        }
                        XposedBridge.log(TAG + ": PHOTO_NO_RAW mode=" + modeName + " removed=[" + removed
                                + "] YUV_LARGE " + added + " -> streams=" + map.keySet());
                    } catch (Throwable t) {
                        XposedBridge.log(TAG + ": PHOTO_NO_RAW error (map left as-is): " + t);
                        XposedBridge.log(t);
                    }
                }
            });
            XposedBridge.log(TAG + ": PHOTO_NO_RAW hook installed on " + HDN_CLASS + ".get()");
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": PHOTO_NO_RAW install failed: " + t);
        }
    }

    /** onResume of every GCam activity: track TeleShot mode, add the TELE button on the main screen. */
    private static void installActivityHooks() {
        try {
            XposedHelpers.findAndHookMethod(android.app.Activity.class, "onResume", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        android.app.Activity act = (android.app.Activity) param.thisObject;
                        android.content.Intent in = act.getIntent();
                        String action = in == null ? null : in.getAction();
                        String cls = act.getClass().getName();
                        boolean capture = android.provider.MediaStore.ACTION_IMAGE_CAPTURE.equals(action);
                        boolean fromTeleShot = false;
                        if (capture) {
                            Object out = in.getParcelableExtra(android.provider.MediaStore.EXTRA_OUTPUT);
                            fromTeleShot = out instanceof android.net.Uri
                                    && TELESHOT_AUTH.equals(((android.net.Uri) out).getAuthority());
                        }
                        teleShotActive = fromTeleShot;
                        if (fromTeleShot && TELESHOT_AUTO_DONE) startAutoDone(act);
                        if (DIAG) XposedBridge.log(TAG + ": onResume " + cls + " action=" + action
                                + " teleShot=" + fromTeleShot);
                        if (TELE_BUTTON && !capture && cls.endsWith(".CameraActivity")) addTeleButton(act);
                    } catch (Throwable t) {
                        XposedBridge.log(TAG + ": activity hook error (ignored): " + t);
                    }
                }
            });
            XposedBridge.log(TAG + ": activity hooks installed (tele button=" + TELE_BUTTON + ")");
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": failed to install activity hooks: " + t);
        }
    }

    private static void addTeleButton(final android.app.Activity act) {
        android.view.ViewGroup decor = (android.view.ViewGroup) act.getWindow().getDecorView();
        android.view.View old = decor.findViewWithTag(BTN_TAG);
        if (old != null) { old.bringToFront(); return; }

        float d = act.getResources().getDisplayMetrics().density;
        int size = Math.round(56 * d);
        android.widget.TextView b = new android.widget.TextView(act);
        b.setTag(BTN_TAG);
        b.setText("TELE");
        b.setTextColor(0xFFFFFFFF);
        b.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 12);
        b.setGravity(android.view.Gravity.CENTER);
        android.graphics.drawable.GradientDrawable bg = new android.graphics.drawable.GradientDrawable();
        bg.setShape(android.graphics.drawable.GradientDrawable.OVAL);
        bg.setColor(0x99000000);
        bg.setStroke(Math.round(1.5f * d), 0xCCFFFFFF);
        b.setBackground(bg);
        b.setElevation(100 * d);
        b.setOnClickListener(new android.view.View.OnClickListener() {
            @Override
            public void onClick(android.view.View v) {
                try {
                    android.content.Intent i = new android.content.Intent();
                    i.setClassName(TELESHOT_PKG, TELESHOT_CLS);
                    act.startActivity(i);
                    XposedBridge.log(TAG + ": TELE button -> TeleShot");
                } catch (Throwable t) {
                    XposedBridge.log(TAG + ": TELE button launch failed: " + t);
                    android.widget.Toast.makeText(act, "TeleShot launch failed: " + t.getMessage(),
                            android.widget.Toast.LENGTH_LONG).show();
                }
            }
        });
        android.widget.FrameLayout.LayoutParams lp = new android.widget.FrameLayout.LayoutParams(size, size,
                android.view.Gravity.END | android.view.Gravity.CENTER_VERTICAL);
        lp.rightMargin = Math.round(12 * d);
        decor.addView(b, lp);
        b.bringToFront();
        XposedBridge.log(TAG + ": TELE button added to " + act.getClass().getName());
    }

    /** Poll the intent screen; when the review (Retake/Done) appears, press Done. */
    private static void startAutoDone(final android.app.Activity act) {
        final android.view.View decor = act.getWindow().getDecorView();
        final String pkg = act.getPackageName();
        final int retakeId = act.getResources().getIdentifier(GCAM_RETAKE_ID, "id", pkg);
        final int shutterId = act.getResources().getIdentifier(GCAM_SHUTTER_ID, "id", pkg);
        if (retakeId == 0 || shutterId == 0) {
            XposedBridge.log(TAG + ": auto-done: ids not found (retake=" + retakeId + " shutter=" + shutterId + ")");
            return;
        }
        XposedBridge.log(TAG + ": auto-done armed");
        decor.postDelayed(new Runnable() {
            int pressedAt = -1;   // tick when we pressed Done
            int tick = 0;
            @Override
            public void run() {
                if (act.isFinishing() || !teleShotActive) return;
                tick++;
                try {
                    android.view.View retake = act.findViewById(retakeId);
                    android.view.View shutter = act.findViewById(shutterId);
                    boolean review = retake != null && retake.isShown() && shutter != null && shutter.isShown();
                    if (review) {
                        if (pressedAt < 0) {
                            pressedAt = tick;
                            boolean ok = shutter.performClick();
                            XposedBridge.log(TAG + ": auto-done: review shown, performClick(Done)=" + ok);
                        } else if (tick - pressedAt == 5) {
                            // still on review ~0.75 s later: synthetic tap in the button centre
                            tap(shutter);
                            XposedBridge.log(TAG + ": auto-done: fallback synthetic tap");
                        }
                    } else {
                        pressedAt = -1;
                    }
                } catch (Throwable t) {
                    XposedBridge.log(TAG + ": auto-done error: " + t);
                }
                decor.postDelayed(this, 150);
            }
        }, 150);
    }

    private static void tap(android.view.View v) {
        long now = android.os.SystemClock.uptimeMillis();
        float x = v.getWidth() / 2f, y = v.getHeight() / 2f;
        android.view.MotionEvent down = android.view.MotionEvent.obtain(now, now, android.view.MotionEvent.ACTION_DOWN, x, y, 0);
        android.view.MotionEvent up = android.view.MotionEvent.obtain(now, now + 60, android.view.MotionEvent.ACTION_UP, x, y, 0);
        v.dispatchTouchEvent(down);
        v.dispatchTouchEvent(up);
        down.recycle();
        up.recycle();
    }

    // v13: LSPatch (integrated) skips the ActivityThread step that seeds
    // FontsContract.sContext, so downloadable-font fetches crash the "fonts" thread:
    // NPE Context.isRestricted() at FontsContract.fetchFonts. Seed it from the
    // Application, and patch a null context at the call site. No-op under LSPosed.
    private static volatile android.content.Context appCtx = null;

    private static void installFontsContextFix() {
        try {
            XposedHelpers.findAndHookMethod(android.app.Application.class, "onCreate", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    try {
                        appCtx = (android.content.Context) param.thisObject;
                        Object cur = XposedHelpers.getStaticObjectField(android.provider.FontsContract.class, "sContext");
                        if (cur == null) {
                            XposedHelpers.setStaticObjectField(android.provider.FontsContract.class, "sContext", appCtx);
                            XposedBridge.log(TAG + ": FONTFIX seeded FontsContract.sContext");
                        }
                    } catch (Throwable t) {
                        XposedBridge.log(TAG + ": FONTFIX seed failed (call-site fix still active): " + t);
                    }
                }
            });
            // v13b: LSPatch loads modules after Application.onCreate, so fix at call time:
            // every FontsContract method whose first arg is a null Context gets the app
            // context, and sContext is seeded the first time we see it null.
            XC_MethodHook nullCtx = new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (param.args.length == 0 || param.args[0] != null) return;
                    android.content.Context c = appCtx;
                    if (c == null) {
                        try { c = (android.content.Context) Class.forName("android.app.ActivityThread").getMethod("currentApplication").invoke(null); } catch (Throwable ignored) {}
                    }
                    if (c == null) return;
                    appCtx = c;
                    param.args[0] = c;
                    try {
                        if (XposedHelpers.getStaticObjectField(android.provider.FontsContract.class, "sContext") == null) {
                            XposedHelpers.setStaticObjectField(android.provider.FontsContract.class, "sContext", c);
                            XposedBridge.log(TAG + ": FONTFIX seeded sContext at call time");
                        }
                    } catch (Throwable t) {
                        XposedBridge.log(TAG + ": FONTFIX sContext seed failed (per-call fix still active): " + t);
                    }
                    XposedBridge.log(TAG + ": FONTFIX null context -> app context");
                }
            };
            for (String m : new String[]{"fetchFonts", "buildTypeface", "requestFonts"}) {
                try {
                    XposedBridge.hookAllMethods(android.provider.FontsContract.class, m, nullCtx);
                } catch (Throwable t) {
                    XposedBridge.log(TAG + ": FONTFIX could not hook " + m + ": " + t);
                }
            }
            XposedBridge.log(TAG + ": FONTFIX v13b hooks installed");
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": FONTFIX install failed: " + t);
        }
    }
}
