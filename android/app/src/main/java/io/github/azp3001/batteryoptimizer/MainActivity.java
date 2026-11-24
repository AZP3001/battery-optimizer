package io.github.azp3001.batteryoptimizer;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import rikka.shizuku.Shizuku;

// The web app from web/ in a WebView. Instead of WebUSB it runs its shell commands through Shizuku, which has the
// same rights as "adb shell" when started with Wireless debugging. index.html picks this up from window.Shizuku.
public class MainActivity extends Activity {
    static final String HOST = "appassets.androidplatform.net";   // reserved for apps, so it never hits the network
    final Map<Integer, Process> procs = new ConcurrentHashMap<>();
    final AtomicInteger nextId = new AtomicInteger();
    volatile boolean denied;
    WebView web;
    ValueCallback<Uri[]> picked;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        web = new WebView(this);
        setContentView(web);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        web.addJavascriptInterface(new Bridge(), "Shizuku");
        Shizuku.addRequestPermissionResultListener((code, result) -> denied = result != PackageManager.PERMISSION_GRANTED);
        web.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView v, WebResourceRequest r) { return serve(r.getUrl()); }

            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                if (HOST.equals(r.getUrl().getHost())) return false;
                try { startActivity(new Intent(Intent.ACTION_VIEW, r.getUrl())); } catch (Exception ignored) {}
                return true;
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams p) {
                if (picked != null) picked.onReceiveValue(null);
                picked = cb;
                Intent i = new Intent(Intent.ACTION_GET_CONTENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                        .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, p.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE);
                try { startActivityForResult(i, 1); } catch (Exception e) { picked = null; return false; }
                return true;
            }
        });
        if (state == null) web.loadUrl("https://" + HOST + "/index.html");
        else web.restoreState(state);
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        if (picked == null) return;
        Uri[] uris = null;
        if (res == RESULT_OK && data != null) {
            ClipData c = data.getClipData();
            if (c != null) {
                uris = new Uri[c.getItemCount()];
                for (int i = 0; i < uris.length; i++) uris[i] = c.getItemAt(i).getUri();
            } else if (data.getData() != null) uris = new Uri[]{data.getData()};
        }
        picked.onReceiveValue(uris);
        picked = null;
    }

    @Override
    protected void onSaveInstanceState(Bundle out) { super.onSaveInstanceState(out); web.saveState(out); }

    @Override
    public void onBackPressed() { if (web.canGoBack()) web.goBack(); else super.onBackPressed(); }

    @Override
    protected void onDestroy() {
        for (Process p : procs.values()) p.destroy();
        super.onDestroy();
    }

    // /__out?id=N streams a command's output, /__exit?id=N waits for it to end and returns the exit code;
    // everything else comes from the app's assets (web/ and the script).
    WebResourceResponse serve(Uri u) {
        if (!HOST.equals(u.getHost())) return null;
        String path = u.getPath() == null ? "/" : u.getPath();
        try {
            if (path.equals("/__out") || path.equals("/__exit")) {
                int id = Integer.parseInt(u.getQueryParameter("id"));
                if (path.equals("/__out")) return response("application/octet-stream", procs.get(id).getInputStream());
                Process p = procs.remove(id);
                return response("text/plain", new ByteArrayInputStream(String.valueOf(p.waitFor()).getBytes()));
            }
            String file = path.equals("/") ? "index.html" : path.substring(1);
            return response(mime(file), getAssets().open(file));
        } catch (Exception e) {
            return new WebResourceResponse("text/plain", "utf-8", 404, "Not found", null, new ByteArrayInputStream(new byte[0]));
        }
    }

    static final Map<String, String> NO_STORE = Collections.singletonMap("Cache-Control", "no-store");

    static WebResourceResponse response(String type, InputStream in) {
        return new WebResourceResponse(type, "utf-8", 200, "OK", NO_STORE, in);
    }

    static String mime(String f) {
        if (f.endsWith(".html")) return "text/html";
        if (f.endsWith(".js")) return "text/javascript";   // ES modules refuse anything else
        if (f.endsWith(".json")) return "application/json";
        return "text/plain";
    }

    class Bridge {
        @JavascriptInterface
        public String status() {
            if (!Shizuku.pingBinder()) return "off";
            if (Shizuku.isPreV11()) return "old";
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) return "ok";
            return denied ? "denied" : "ask";
        }

        @JavascriptInterface
        public void ask() { denied = false; Shizuku.requestPermission(1); }

        // stderr is merged into stdout, like the web app gets over adb.
        @JavascriptInterface
        public int start(String cmd) throws Exception {
            Process p = (Process) newProcess().invoke(null, new String[]{"sh", "-c", "exec 2>&1; " + cmd}, null, null);
            int id = nextId.incrementAndGet();
            procs.put(id, p);
            return id;
        }

        @JavascriptInterface
        public void write(int id, String base64) throws Exception { procs.get(id).getOutputStream().write(Base64.decode(base64, Base64.NO_WRAP)); }

        @JavascriptInterface
        public void closeIn(int id) throws Exception { procs.get(id).getOutputStream().close(); }

        @JavascriptInterface
        public void kill(int id) { Process p = procs.get(id); if (p != null) p.destroy(); }
    }

    // shortcut: Shizuku.newProcess is private in API 13 (still present); move to a Shizuku UserService if a later API drops it.
    static Method newProcessMethod;
    static Method newProcess() throws Exception {
        if (newProcessMethod == null) {
            newProcessMethod = Shizuku.class.getDeclaredMethod("newProcess", String[].class, String[].class, String.class);
            newProcessMethod.setAccessible(true);
        }
        return newProcessMethod;
    }
}
