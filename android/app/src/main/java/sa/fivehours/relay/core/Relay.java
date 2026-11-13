package sa.fivehours.relay.core;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * The relayed message, format v1 (read by fn_bank_relay_parse and checked by fn_bank_process, migration 0066):
 * <pre>
 *   FIVEHOURS-RELAY 1
 *   sender: &lt;the SMS sender or the app that notified&gt;
 *   received: &lt;ISO time on the phone&gt;
 *   channel: sms | notification
 *   signature: &lt;hex HMAC-SHA256(relay key, sender \n received \n channel \n text)&gt;
 *   ---
 *   &lt;the text, exactly&gt;
 * </pre>
 * The text is relayed as it came; only line ends are made \n and the trailing ones taken off, as the server does
 * before it checks the signature.
 */
public final class Relay {
    private Relay() {}

    public static final String HEADER = "FIVEHOURS-RELAY 1";

    /** the text as the server will read it */
    public static String canonicalText(String text) {
        String t = (text == null ? "" : text).replace("\r\n", "\n").replace('\r', '\n');
        int end = t.length();
        while (end > 0 && t.charAt(end - 1) == '\n') end--;
        return t.substring(0, end);
    }

    /** a header value is one line, trimmed */
    public static String oneLine(String v) {
        return (v == null ? "" : v).replaceAll("[\\r\\n]+", " ").trim();
    }

    public static String sign(String key, String sender, String received, String channel, String text) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            byte[] d = mac.doFinal((sender + "\n" + received + "\n" + channel + "\n" + text).getBytes(StandardCharsets.UTF_8));
            return hex(d);
        } catch (Exception e) {
            throw new IllegalStateException("hmac", e);
        }
    }

    /** the body of the email for one message */
    public static String body(String key, String sender, String received, String channel, String text) {
        if (!"sms".equals(channel) && !"notification".equals(channel)) throw new IllegalArgumentException("channel");
        String s = oneLine(sender), r = oneLine(received), t = canonicalText(text);
        return HEADER + "\n"
            + "sender: " + s + "\n"
            + "received: " + r + "\n"
            + "channel: " + channel + "\n"
            + "signature: " + sign(key, s, r, channel, t) + "\n"
            + "---\n"
            + t + "\n";
    }

    /** the same message (the same sender, time and text) is the same: the outbox keeps it once */
    public static String id(String sender, String received, String text) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            return hex(md.digest((oneLine(sender) + "\n" + oneLine(received) + "\n" + canonicalText(text)).getBytes(StandardCharsets.UTF_8))).substring(0, 32);
        } catch (Exception e) {
            throw new IllegalStateException("sha", e);
        }
    }

    static String hex(byte[] d) {
        StringBuilder b = new StringBuilder(d.length * 2);
        for (byte x : d) b.append(String.format("%02x", x & 0xff));
        return b.toString();
    }
}
