import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.os.Looper;
import java.lang.reflect.Method;
import java.security.MessageDigest;
import org.json.JSONArray;
import org.json.JSONObject;

/** Runs in adb's shell app_process; no helper application is installed. */
public final class PackageArchiveProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("APK path required");
        Looper.prepareMainLooper();
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Method systemMain = activityThread.getDeclaredMethod("systemMain");
        systemMain.setAccessible(true);
        Object thread = systemMain.invoke(null);
        Method getSystemContext = activityThread.getDeclaredMethod("getSystemContext");
        getSystemContext.setAccessible(true);
        Context context = (Context) getSystemContext.invoke(thread);
        PackageInfo info = context.getPackageManager().getPackageArchiveInfo(
                args[0], PackageManager.GET_ACTIVITIES | PackageManager.GET_SIGNATURES);
        JSONObject result = new JSONObject();
        result.put("package_info_null", info == null);
        if (info != null) {
            result.put("package", info.packageName);
            result.put("version_name", info.versionName);
            result.put("version_code", info.versionCode);
            JSONArray certificates = new JSONArray();
            if (info.signatures != null) {
                for (Signature signature : info.signatures) {
                    byte[] hash = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray());
                    StringBuilder hex = new StringBuilder();
                    for (byte value : hash) hex.append(String.format("%02x", value & 0xff));
                    certificates.put(hex.toString());
                }
            }
            result.put("certificate_sha256", certificates);
        }
        System.out.println("AIPLAYER_ARCHIVE_INFO=" + result.toString());
        System.exit(info == null ? 2 : 0);
    }
}
