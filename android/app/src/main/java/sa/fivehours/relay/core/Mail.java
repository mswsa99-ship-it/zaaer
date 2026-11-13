package sa.fivehours.relay.core;

import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Base64;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

/** One email as the bank-mail function reads it (supabase/functions/_shared/mime.ts): from the app's mailbox to itself,
 *  a plain-text UTF-8 body in base64, so no line of the bank's text is changed on the way. */
public final class Mail {
    private Mail() {}

    public static String build(String mailbox, String body, Date date, String id) {
        SimpleDateFormat f = new SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss Z", Locale.US);
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        String b64 = Base64.getMimeEncoder(76, "\r\n".getBytes(StandardCharsets.US_ASCII)).encodeToString(body.getBytes(StandardCharsets.UTF_8));
        String domain = mailbox.substring(mailbox.indexOf('@') + 1);
        return "From: <" + mailbox + ">\r\n"
            + "To: <" + mailbox + ">\r\n"
            + "Subject: FIVEHOURS-RELAY\r\n"
            + "Date: " + f.format(date) + "\r\n"
            + "Message-ID: <relay-" + id + "@" + domain + ">\r\n"
            + "MIME-Version: 1.0\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Transfer-Encoding: base64\r\n"
            + "\r\n"
            + b64 + "\r\n";
    }
}
