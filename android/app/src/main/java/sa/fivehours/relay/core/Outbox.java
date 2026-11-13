package sa.fivehours.relay.core;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * The messages waiting to be sent, one file each in the app's private folder, oldest first. A message is written
 * before anything is sent and removed only once the mail server accepted it, so a phone without internet, or
 * switched off, sends it later. Nothing else is kept: a sent message leaves the phone (one the mail server refuses is
 * set aside, so it does not hold the others back). The same message (sender,
 * time, text — the SMS and a second delivery of it) is queued once.
 */
public final class Outbox {
    private final File dir;

    public Outbox(File dir) {
        this.dir = dir;
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IllegalStateException("outbox");
    }

    /** false when this message is already waiting */
    public synchronized boolean add(String id, String mail) throws IOException {
        if (!id.matches("[0-9a-f]{32}")) throw new IllegalArgumentException("id");
        for (File f : files()) if (f.getName().endsWith("-" + id + ".eml")) return false;
        String name = String.format("%016d-%s.eml", System.currentTimeMillis(), id);
        File tmp = new File(dir, name + ".tmp");
        try (FileOutputStream o = new FileOutputStream(tmp)) {
            o.write(mail.getBytes(StandardCharsets.UTF_8));
            o.getFD().sync();
        }
        if (!tmp.renameTo(new File(dir, name))) throw new IOException("outbox rename");
        return true;
    }

    public synchronized List<File> files() {
        File[] all = dir.listFiles((d, n) -> n.endsWith(".eml"));
        if (all == null) return new ArrayList<>();
        Arrays.sort(all, (a, b) -> a.getName().compareTo(b.getName()));
        return new ArrayList<>(Arrays.asList(all));
    }

    public int size() { return files().size(); }

    public static String read(File f) throws IOException { return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8); }

    public synchronized void remove(File f) { if (f.exists() && !f.delete()) f.deleteOnExit(); }

    /** a message the mail server refused (its size, its content): kept apart so the others go on; the screen counts it */
    public synchronized void setAside(File f) {
        File aside = new File(dir, "refused");
        if (!aside.isDirectory()) aside.mkdirs();
        if (!f.renameTo(new File(aside, f.getName()))) remove(f);
    }

    public int setAsideCount() {
        File[] a = new File(dir, "refused").listFiles((d, n) -> n.endsWith(".eml"));
        return a == null ? 0 : a.length;
    }
}
