package sa.fivehours.relay.app;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import sa.fivehours.relay.core.Config;
import sa.fivehours.relay.core.Outbox;
import sa.fivehours.relay.core.Relayer;

/**
 * The app's settings, in its private storage: the setup text (no secret in it), and the relay key and the mailbox
 * password each encrypted with a key that never leaves the phone's keystore. The last sending result, for the screen.
 */
final class Store {
    private static final String ALIAS = "fivehours-relay";
    private final Context ctx;
    private final SharedPreferences p;

    Store(Context ctx) {
        this.ctx = ctx.getApplicationContext();
        this.p = this.ctx.getSharedPreferences("relay", Context.MODE_PRIVATE);
    }

    Outbox outbox() { return new Outbox(new File(ctx.getFilesDir(), "outbox")); }

    Relayer relayer() { return new Relayer(outbox()); }

    /** null until the owner saved a setup text */
    Config config() {
        String t = p.getString("setup", null);
        if (t == null) return null;
        try { return Config.parse(t); } catch (IllegalArgumentException e) { return null; }
    }

    String key() { return open(p.getString("key", null)); }

    String password() { return open(p.getString("password", null)); }

    /** saves the setup text; the key only when the text carries one; the password only when one was typed */
    void save(Config c, String password) {
        SharedPreferences.Editor e = p.edit().putString("setup", c.format());
        if (c.key != null) e.putString("key", seal(c.key));
        if (password != null && !password.isEmpty()) e.putString("password", seal(password));
        e.remove("error").apply();
    }

    void result(Relayer.Result r) {
        SharedPreferences.Editor e = p.edit();
        if (r.sent > 0) e.putLong("last_sent", System.currentTimeMillis());
        if (r.setAside > 0) e.putInt("set_aside", p.getInt("set_aside", 0) + r.setAside);
        if (r.error == null) e.remove("error");
        else e.putString("error", r.refused() ? "refused" : "network");
        e.apply();
    }

    long lastSent() { return p.getLong("last_sent", 0); }

    /** apps whose notification carried an account number but are not allowed senders (their package names only, the
     *  last five), so the owner sees which one to add */
    void noteUnknownApp(String pkg) {
        String prev = p.getString("unknown_apps", "");
        java.util.LinkedHashSet<String> s = new java.util.LinkedHashSet<>();
        s.add(pkg);
        for (String x : prev.split(",")) if (!x.isEmpty() && s.size() < 5) s.add(x);
        p.edit().putString("unknown_apps", String.join(",", s)).apply();
    }

    String unknownApps() { return p.getString("unknown_apps", ""); }

    int setAside() { return p.getInt("set_aside", 0); }

    String error() { return p.getString("error", null); }

    String keyEnd() { String k = key(); return k == null ? null : k.substring(Math.max(0, k.length() - 4)); }

    // ---- the phone's keystore
    private static SecretKey secret() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (!ks.containsAlias(ALIAS)) {
            KeyGenerator g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            g.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            return g.generateKey();
        }
        return (SecretKey) ks.getKey(ALIAS, null);
    }

    private static String seal(String plain) {
        try {
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, secret());
            byte[] ct = c.doFinal(plain.getBytes(StandardCharsets.UTF_8));
            return Base64.getEncoder().encodeToString(c.getIV()) + ":" + Base64.getEncoder().encodeToString(ct);
        } catch (Exception e) {
            throw new IllegalStateException("keystore", e);
        }
    }

    private static String open(String sealed) {
        if (sealed == null) return null;
        try {
            String[] parts = sealed.split(":");
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, secret(), new GCMParameterSpec(128, Base64.getDecoder().decode(parts[0])));
            return new String(c.doFinal(Base64.getDecoder().decode(parts[1])), StandardCharsets.UTF_8);
        } catch (Exception e) {
            return null;
        }
    }
}
