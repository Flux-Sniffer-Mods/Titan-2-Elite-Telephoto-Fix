package com.fluxsniffer.telezoom;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.util.Log;

import java.io.File;
import java.io.FileNotFoundException;

/** Minimal FileProvider: content://com.fluxsniffer.telezoom.shot/<name> -> cacheDir/shots/<name>. */
public class ShotProvider extends ContentProvider {
    static final String AUTH = "com.fluxsniffer.telezoom.shot";
    private static final String TAG = "TeleShot";

    static File dir(android.content.Context c) {
        File d = new File(c.getCacheDir(), "shots");
        d.mkdirs();
        return d;
    }

    private File fileFor(Uri u) throws FileNotFoundException {
        String name = u.getLastPathSegment();
        if (name == null || name.contains("/") || name.contains("..")) throw new FileNotFoundException("bad name");
        return new File(dir(getContext()), name);
    }

    @Override public boolean onCreate() { return true; }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        File f = fileFor(uri);
        Log.i(TAG, "provider openFile mode=" + mode + " file=" + f + " callingPkg=" + getCallingPackage());
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.parseMode(mode));
    }

    @Override public String getType(Uri uri) { return "image/jpeg"; }

    @Override
    public Cursor query(Uri uri, String[] proj, String sel, String[] args, String sort) {
        Log.i(TAG, "provider query " + uri);
        try {
            File f = fileFor(uri);
            MatrixCursor c = new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
            c.addRow(new Object[]{f.getName(), f.length()});
            return c;
        } catch (Throwable t) {
            return null;
        }
    }

    @Override public Uri insert(Uri uri, ContentValues v) { return null; }
    @Override public int delete(Uri uri, String s, String[] a) { return 0; }
    @Override public int update(Uri uri, ContentValues v, String s, String[] a) { return 0; }
}
