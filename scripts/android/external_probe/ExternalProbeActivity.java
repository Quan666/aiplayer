package app.aiplayer.externalprobe;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;
import java.io.File;

/** Starts the real exported player activity with a temporary content URI grant. */
public final class ExternalProbeActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView status = new TextView(this);
        status.setPadding(24, 24, 24, 24);
        setContentView(status);
        String token = getIntent().getStringExtra("case");
        if (token == null) token = "view_cold";
        Uri base = new Uri.Builder().scheme("content").authority("app.aiplayer.externalprobe.files").appendPath("files").appendPath(token).build();
        ProbeContentProvider.token(base);
        if (getIntent().getBooleanExtra("revoke", false)) {
            String granted = getSharedPreferences("issued", 0).getString(token, base.toString());
            revokeUriPermission(Uri.parse(granted), Intent.FLAG_GRANT_READ_URI_PERMISSION);
            getSharedPreferences("revoked", 0).edit().putBoolean(token, true).commit();
            new File(getFilesDir(), token + ".mp4").delete();
            status.setText("Source revoked and removed: " + token);
            Log.i("AIPlayerExternalProbe", "revoked " + token);
            finish();
            return;
        }
        getSharedPreferences("revoked", 0).edit().remove(token).commit();
        String name = getIntent().getStringExtra("name");
        if (name == null) name = "外部打开测试 " + token + ".mp4";
        Uri uri = base.buildUpon().appendQueryParameter("name", name)
            .appendQueryParameter("query_delay_ms", String.valueOf(getIntent().getIntExtra("query_delay_ms", 0))).build();
        getSharedPreferences("issued", 0).edit().putString(token, uri.toString()).commit();
        boolean send = "SEND".equals(getIntent().getStringExtra("action"));
        Intent target = new Intent(send ? Intent.ACTION_SEND : Intent.ACTION_VIEW);
        target.setPackage("app.aiplayer.aiplayer");
        target.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        target.setClipData(ClipData.newRawUri("probe video", uri));
        if (send) { target.setType("video/mp4"); target.putExtra(Intent.EXTRA_STREAM, uri); }
        else target.setDataAndType(uri, "video/mp4");
        try {
            startActivity(target);
            status.setText("Sent " + (send ? "ACTION_SEND" : "ACTION_VIEW") + ": " + token);
            Log.i("AIPlayerExternalProbe", "sent " + (send ? "SEND " : "VIEW ") + token);
            finish();
        } catch (Exception error) {
            status.setText("Probe failed: " + error.getClass().getSimpleName());
            Log.e("AIPlayerExternalProbe", "Unable to resolve or launch target", error);
        }
    }
}
