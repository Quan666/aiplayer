package app.aiplayer.externalprobe;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.InputStream;

/** Test-only, non-exported provider: another app can read only with a URI grant. */
public final class ProbeContentProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }
    static String token(Uri uri) {
        String token = uri.getLastPathSegment();
        if (token == null || !token.matches("[A-Za-z0-9_-]{1,60}")) throw new IllegalArgumentException("Invalid probe token");
        return token;
    }
    private File fixture(Uri uri) throws FileNotFoundException {
        String token = token(uri);
        if (getContext().getSharedPreferences("revoked", 0).getBoolean(token, false)) throw new FileNotFoundException("Probe source has been revoked");
        File file = new File(getContext().getFilesDir(), token + ".mp4");
        if (!file.exists()) {
            try (InputStream in = getContext().getAssets().open("fixture.mp4"); FileOutputStream out = new FileOutputStream(file)) {
                byte[] bytes = new byte[65536];
                for (int count; (count = in.read(bytes)) >= 0;) out.write(bytes, 0, count);
            } catch (Exception error) { throw new FileNotFoundException("Unable to prepare probe fixture"); }
        }
        return file;
    }
    @Override public String getType(Uri uri) { return "video/mp4"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        try {
            String delay = uri.getQueryParameter("query_delay_ms");
            if (delay != null) Thread.sleep(Math.min(5000, Math.max(0, Long.parseLong(delay))));
            File file = fixture(uri);
            String[] columns = projection == null ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
            MatrixCursor cursor = new MatrixCursor(columns);
            Object[] values = new Object[columns.length];
            for (int i = 0; i < columns.length; i++) {
                if (OpenableColumns.DISPLAY_NAME.equals(columns[i])) values[i] = uri.getQueryParameter("name");
                else if (OpenableColumns.SIZE.equals(columns[i])) values[i] = file.length();
            }
            cursor.addRow(values);
            return cursor;
        } catch (Exception error) { throw new IllegalStateException("Probe query unavailable", error); }
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Read only");
        return ParcelFileDescriptor.open(fixture(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
