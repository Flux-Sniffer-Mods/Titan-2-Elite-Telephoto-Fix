package com.fluxsniffer.telezoom;

import android.app.Activity;
import android.content.ClipData;
import android.content.ContentValues;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.provider.MediaStore;
import android.util.Log;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * TeleShot v12 — tele stills via GCam's IMAGE_INTENT mode (no RAW stream, so the
 * SAT HAL can use the 6.8mm tele under the TeleZoom hooks).
 * v8 handed GCam a PENDING MediaStore entry, which other apps cannot open -> GCam
 * returned CANCELED. Now GCam writes to our own provider (cache file), and we copy
 * the result into DCIM/Camera ourselves.
 */
public class TeleShot extends Activity {
    private static final String TAG = "TeleShot";
    private static final String GCAM_PKG = "com.google.android.GoogleCameraEngR18F1";
    private static final int REQ = 1;
    private static final String K_NAME = "name";
    private static final boolean LOOP = true; // v12: relaunch after every saved shot; X/back exits

    private String name;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (state != null) {
            name = state.getString(K_NAME);
            return;
        }
        launch();
    }

    /** Fresh output name + GCam IMAGE_CAPTURE. Called at start and after every saved shot. */
    private void launch() {
        try {
            name = "TELE_" + new SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(new Date()) + ".jpg";
            File f = new File(ShotProvider.dir(this), name);
            f.delete();
            Uri out = Uri.parse("content://" + ShotProvider.AUTH + "/" + name);

            Intent i = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
            i.setPackage(GCAM_PKG);
            i.putExtra(MediaStore.EXTRA_OUTPUT, out);
            i.setClipData(ClipData.newRawUri("output", out));
            i.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION);
            Log.i(TAG, "v12 launching GCam IMAGE_CAPTURE -> " + out);
            startActivityForResult(i, REQ);
        } catch (Throwable t) {
            Log.e(TAG, "start failed", t);
            Toast.makeText(this, "TeleShot: " + t.getMessage(), Toast.LENGTH_LONG).show();
            finish();
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        out.putString(K_NAME, name);
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != REQ) return;
        File f = new File(ShotProvider.dir(this), name);
        long size = f.exists() ? f.length() : -1;
        Log.i(TAG, "GCam result=" + res + " cacheSize=" + size + " data=" + data);
        if (size > 0) {
            stampExif(f);
            String err = publish(f);
            f.delete();
            Toast.makeText(this, err == null ? "Saved " + name : "TeleShot: " + err, Toast.LENGTH_SHORT).show();
            if (LOOP && err == null) {   // stay in tele mode: straight back to GCam for the next shot
                launch();
                return;
            }
        } else {
            f.delete();
            Log.i(TAG, "no image (" + (res == RESULT_OK ? "OK" : "CANCELED") + ") -> leaving TeleShot");
        }
        finish();
    }

    /** Copy the cache file into DCIM/Camera via MediaStore. Returns null on success. */
    private String publish(File f) {
        Uri dst = null;
        try {
            ContentValues cv = new ContentValues();
            cv.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
            cv.put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg");
            cv.put(MediaStore.MediaColumns.RELATIVE_PATH, "DCIM/Camera");
            cv.put(MediaStore.MediaColumns.IS_PENDING, 1);
            dst = getContentResolver().insert(
                    MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), cv);
            if (dst == null) return "MediaStore insert failed";
            try (InputStream in = new FileInputStream(f);
                 OutputStream os = getContentResolver().openOutputStream(dst)) {
                if (os == null) throw new IllegalStateException("no output stream");
                byte[] buf = new byte[1 << 16];
                int n;
                while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
            }
            ContentValues done = new ContentValues();
            done.put(MediaStore.MediaColumns.IS_PENDING, 0);
            getContentResolver().update(dst, done, null, null);
            Log.i(TAG, "published " + name + " -> " + dst);
            return null;
        } catch (Throwable t) {
            Log.e(TAG, "publish failed", t);
            if (dst != null) try { getContentResolver().delete(dst, null, null); } catch (Throwable ignored) {}
            return "save failed: " + t;
        }
    }

    /** GCam's intent path omits DateTimeOriginal; add it so the gallery sorts the shot correctly. */
    private void stampExif(File f) {
        try {
            android.media.ExifInterface ex = new android.media.ExifInterface(f.getAbsolutePath());
            if (ex.getAttribute(android.media.ExifInterface.TAG_DATETIME_ORIGINAL) == null) {
                String now = new SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US).format(new Date());
                ex.setAttribute(android.media.ExifInterface.TAG_DATETIME_ORIGINAL, now);
                ex.setAttribute(android.media.ExifInterface.TAG_DATETIME_DIGITIZED, now);
                if (ex.getAttribute(android.media.ExifInterface.TAG_DATETIME) == null)
                    ex.setAttribute(android.media.ExifInterface.TAG_DATETIME, now);
                ex.saveAttributes();
                Log.i(TAG, "stamped DateTimeOriginal=" + now);
            }
        } catch (Throwable t) {
            Log.w(TAG, "exif stamp failed (saving anyway): " + t);
        }
    }
}
