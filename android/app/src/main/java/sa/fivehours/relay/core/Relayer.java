package sa.fivehours.relay.core;

import java.io.File;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;

/**
 * What the app does, and all it does (plan A9): a message of an allowed bank sender that carries the number of one of
 * the branches' accounts is put, as it is and signed, in the outbox; the outbox is sent to the app's mailbox, and what
 * could not be sent stays for the next try. Every other message is left alone — not read further, not kept, not sent.
 */
public final class Relayer {
    public enum Verdict { QUEUED, ALREADY_QUEUED, NOT_SET_UP, SENDER_NOT_ALLOWED, NO_ACCOUNT_NUMBER }

    private final Outbox outbox;

    public Relayer(Outbox outbox) { this.outbox = outbox; }

    public static String iso(long millis) {
        SimpleDateFormat f = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US);
        f.setTimeZone(TimeZone.getTimeZone("Asia/Riyadh"));
        return f.format(new Date(millis));
    }

    /** one SMS or notification as it arrived */
    public Verdict accept(Config c, String key, String sender, long receivedAt, String channel, String text) throws IOException {
        if (c == null || key == null || key.isEmpty()) return Verdict.NOT_SET_UP;
        if (!c.allows(sender)) return Verdict.SENDER_NOT_ALLOWED;
        if (!AccountRules.matches(text, c.accounts)) return Verdict.NO_ACCOUNT_NUMBER;
        String received = iso(receivedAt);
        String id = Relay.id(sender, received, text);
        String mail = Mail.build(c.mailbox, Relay.body(key, sender, received, channel, text), new Date(receivedAt), id);
        return outbox.add(id, mail) ? Verdict.QUEUED : Verdict.ALREADY_QUEUED;
    }

    public static final class Result {
        public final int sent; public final int waiting; public final IOException error;
        Result(int sent, int waiting, IOException error) { this.sent = sent; this.waiting = waiting; this.error = error; }
        public boolean refused() { return error instanceof Smtp.Refused; }
    }

    /** sends what waits, in batches of 20, oldest first; stops at the first failure (the rest waits) */
    public Result flush(Config c, Smtp smtp) {
        int sent = 0;
        while (true) {
            List<File> batch = outbox.files();
            if (batch.isEmpty()) return new Result(sent, 0, null);
            if (batch.size() > 20) batch = batch.subList(0, 20);
            List<String> mails = new ArrayList<>();
            try {
                for (File f : batch) mails.add(Outbox.read(f));
                int n = smtp.send(c.mailbox, mails);
                for (int i = 0; i < n; i++) outbox.remove(batch.get(i));
                sent += n;
            } catch (IOException e) {
                return new Result(sent, outbox.size(), e);
            }
        }
    }
}
