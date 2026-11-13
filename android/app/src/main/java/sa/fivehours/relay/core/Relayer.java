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
        public final int sent; public final int setAside; public final int waiting; public final IOException error;
        Result(int sent, int setAside, int waiting, IOException error) { this.sent = sent; this.setAside = setAside; this.waiting = waiting; this.error = error; }
        /** the login was refused: nothing goes until the password (or the login) is corrected */
        public boolean refused() { return error instanceof Smtp.Refused && ((Smtp.Refused) error).login; }
    }

    /**
     * Sends what waits, in batches of 20, oldest first. Each message leaves the outbox as soon as the server accepted
     * it; one the server refuses is set aside and the rest go on; a lost connection or a refused login stops the round
     * (what is left waits for the next try).
     */
    public Result flush(Config c, Smtp smtp) {
        final int[] sent = { 0 }, aside = { 0 };
        while (true) {
            List<File> files = outbox.files();
            if (files.isEmpty()) return new Result(sent[0], aside[0], 0, null);
            final List<File> batch = files.size() > 20 ? files.subList(0, 20) : files;
            List<String> mails = new ArrayList<>();
            try {
                for (File f : batch) mails.add(Outbox.read(f));
                smtp.send(c.mailbox, mails, new Smtp.Listener() {
                    @Override public void accepted(int i) { outbox.remove(batch.get(i)); sent[0]++; }
                    @Override public void refused(int i, Smtp.Refused why) { outbox.setAside(batch.get(i)); aside[0]++; }
                });
            } catch (IOException e) {
                return new Result(sent[0], aside[0], outbox.size(), e);
            }
        }
    }
}
