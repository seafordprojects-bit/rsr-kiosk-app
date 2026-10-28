package ph.rsr.kiosk;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** Tiny HTTP helpers (no libraries). All calls run on the background thread. */
final class Net {
    private Net() {}

    /** Calls a Supabase RPC with the public anon key. Returns the response body, or throws. */
    static String rpc(String fn, String jsonBody) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(Config.SUPABASE_URL + "/rest/v1/rpc/" + fn).openConnection();
        try {
            c.setConnectTimeout(15_000);
            c.setReadTimeout(15_000);
            c.setRequestMethod("POST");
            c.setDoOutput(true);
            c.setRequestProperty("apikey", Config.SUPABASE_ANON_KEY);
            c.setRequestProperty("Authorization", "Bearer " + Config.SUPABASE_ANON_KEY);
            c.setRequestProperty("Content-Type", "application/json");
            c.setRequestProperty("Accept", "application/json");
            try (OutputStream o = c.getOutputStream()) {
                o.write(jsonBody.getBytes(StandardCharsets.UTF_8));
            }
            int code = c.getResponseCode();
            String body = read(code >= 400 ? c.getErrorStream() : c.getInputStream());
            if (code >= 400) throw new IOException("HTTP " + code + " " + body);
            return body;
        } finally {
            c.disconnect();
        }
    }

    static String get(String url) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        try {
            c.setConnectTimeout(15_000);
            c.setReadTimeout(20_000);
            c.setRequestProperty("Accept", "application/vnd.github+json");
            c.setRequestProperty("User-Agent", "rsr-kiosk-app");
            int code = c.getResponseCode();
            String body = read(code >= 400 ? c.getErrorStream() : c.getInputStream());
            if (code >= 400) throw new IOException("HTTP " + code);
            return body;
        } finally {
            c.disconnect();
        }
    }

    /** Opens a download (follows GitHub's https redirect to its file host). Caller closes the stream. */
    static HttpURLConnection openDownload(String url) throws IOException {
        String u = url;
        for (int hop = 0; hop < 5; hop++) {
            HttpURLConnection c = (HttpURLConnection) new URL(u).openConnection();
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(20_000);
            c.setReadTimeout(60_000);
            c.setRequestProperty("Accept", "application/octet-stream");
            c.setRequestProperty("User-Agent", "rsr-kiosk-app");
            int code = c.getResponseCode();
            if (code >= 300 && code < 400) {
                String loc = c.getHeaderField("Location");
                c.disconnect();
                if (loc == null || !loc.startsWith("https://")) throw new IOException("bad redirect");
                u = loc;
                continue;
            }
            if (code != 200) { c.disconnect(); throw new IOException("HTTP " + code); }
            return c;
        }
        throw new IOException("too many redirects");
    }

    private static String read(InputStream in) throws IOException {
        if (in == null) return "";
        try (InputStream i = in) {
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = i.read(buf)) > 0) b.write(buf, 0, n);
            return b.toString("UTF-8");
        }
    }
}
