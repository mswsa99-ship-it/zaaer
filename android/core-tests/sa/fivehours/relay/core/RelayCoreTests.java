package sa.fivehours.relay.core;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.security.KeyStore;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLServerSocketFactory;
import javax.net.ssl.TrustManagerFactory;

/**
 * The phone app's rules, tried without a phone (A9; RL* in tests/acceptance-library.json). Plain Java, no test
 * library: `bash tests/android/run.sh` compiles and runs it. Writes the sample email the server-side checks read
 * (tests/android/fixtures/relay-sample.eml) and fails if it differs from the one kept in the repository.
 */
public final class RelayCoreTests {
    static int passed = 0, failed = 0;

    static void check(String name, boolean ok, String detail) {
        if (ok) { passed++; System.out.println("PASS " + name); }
        else { failed++; System.out.println("FAIL " + name + (detail == null ? "" : " — " + detail)); }
    }

    static final String KEY = "0123456789abcdef0123456789abcdef0123456789abcdef";
    static final String SETUP = "FIVEHOURS-SETUP 1\nmailbox: Relay.Test@example.com\nsmtp: smtp.example.com:465\n"
        + "senders: AlRajhiBank, Alrajhi, الراجحي\naccount: 605…4321\naccount: ٣٤٦...٧٧٨٨\nkey: " + KEY + "\n";
    static final String SAMPLE_TEXT = "حوالة واردة\r\nمبلغ: ٤٥٠ SAR\r\nإلى: 605****4321\r\nرقم المرجع: AND1001\r\n13/11/26 09:12\r\n";
    static final long SAMPLE_AT = 1794550320000L;   // 2026-11-13 09:12:00 Riyadh (06:12 UTC)

    public static void main(String[] args) throws Exception {
        File work = Files.createTempDirectory("relay-tests").toFile();
        Config c = Config.parse(SETUP);

        // RL01 the setup text
        boolean bad = false;
        for (String s : new String[] { "", "FIVEHOURS-SETUP 2\nmailbox: a@b.co", SETUP.replace("account: 605…4321\n", "account: 6…4321\n"),
                SETUP.replace("mailbox: Relay.Test@example.com\n", ""), SETUP.replace("smtp: smtp.example.com:465", "smtp: smtp.example.com:99999") }) {
            try { Config.parse(s); bad = true; } catch (Config.Invalid e) { /* refused, as it should */ }
        }
        Config noKey = Config.parse(SETUP.replace("key: " + KEY + "\n", ""));
        check("RL01 the setup text from «بريد البنك» gives the mailbox, the mail server, the senders and each account's rule; a broken one is refused; without a key line the phone keeps its key",
            !bad && c.mailbox.equals("relay.test@example.com") && c.smtpPort == 465 && c.senders.size() == 3 && c.accounts.size() == 2
                && c.accounts.get(1).prefix.equals("346") && c.accounts.get(1).suffix.equals("7788") && KEY.equals(c.key) && noKey.key == null
                && Config.parse(c.format()).accounts.size() == 2 && c.user.equals(c.mailbox)
                && Config.parse(SETUP.replace("smtp:", "user: owner@workspace.example\nsmtp:")).user.equals("owner@workspace.example"), null);

        // RL02 the account rule, as the server reads it
        List<AccountRules.Rule> rules = c.accounts;
        String[][] yes = { { "إلى: 605****4321" }, { "حساب ٦٠٥*****٤٣٢١" }, { "account **4321 credited" }, { "IBAN 6051234567894321 ok" }, { "من 346xx7788" } };
        String[][] no = { { "إلى: 605****1111" }, { "إلى: 999****4321" }, { "جوال 0551234321" }, { "**21" }, { "رسالة ترويجية" }, { "رقم قصير 6054321" } };
        boolean allYes = true, allNo = true;
        for (String[] t : yes) allYes &= AccountRules.matches(t[0], rules);
        for (String[] t : no) allNo &= !AccountRules.matches(t[0], rules);
        check("RL02 only a message carrying one of the accounts' numbers (masked, its end, or whole; Arabic digits too) is relayed; another account, a phone number or no number is not",
            allYes && allNo && AccountRules.fits("605****4321", "605", "4321") && !AccountRules.fits("605****4321", "606", "4321")
                && AccountRules.fits("**321", "605", "4321") && !AccountRules.fits("**21", "605", "4321"), null);

        // RL03 what the app does with each message
        Outbox box = new Outbox(new File(work, "outbox"));
        Relayer r = new Relayer(box);
        Relayer.Verdict v1 = r.accept(c, KEY, "AlRajhiBank", SAMPLE_AT, "sms", SAMPLE_TEXT);
        Relayer.Verdict v2 = r.accept(c, KEY, "AlRajhiBank", SAMPLE_AT, "sms", SAMPLE_TEXT);
        Relayer.Verdict v3 = r.accept(c, KEY, "SomeShop", SAMPLE_AT, "sms", SAMPLE_TEXT);
        Relayer.Verdict v4 = r.accept(c, KEY, "alrajhibank", SAMPLE_AT, "sms", "رمز التحقق 1234 لا تشاركه");
        Relayer.Verdict v5 = r.accept(null, KEY, "AlRajhiBank", SAMPLE_AT, "sms", SAMPLE_TEXT);
        Relayer.Verdict v6 = r.accept(c, null, "AlRajhiBank", SAMPLE_AT, "sms", SAMPLE_TEXT);
        check("RL03 a bank message with an account number is queued once; another sender, a message with no account number (a one-time code) and an app not set up queue nothing",
            v1 == Relayer.Verdict.QUEUED && v2 == Relayer.Verdict.ALREADY_QUEUED && v3 == Relayer.Verdict.SENDER_NOT_ALLOWED
                && v4 == Relayer.Verdict.NO_ACCOUNT_NUMBER && v5 == Relayer.Verdict.NOT_SET_UP && v6 == Relayer.Verdict.NOT_SET_UP && box.size() == 1,
            v1 + " " + v2 + " " + v3 + " " + v4 + " " + v5 + " " + v6 + " size " + box.size());

        // RL04 the email: the text as it came, signed
        String mail = Outbox.read(box.files().get(0));
        String body = new String(Base64.getMimeDecoder().decode(mail.substring(mail.indexOf("\r\n\r\n") + 4)), StandardCharsets.UTF_8);
        String text = Relay.canonicalText(SAMPLE_TEXT);
        String expectSig = Relay.sign(KEY, "AlRajhiBank", Relayer.iso(SAMPLE_AT), "sms", text);
        check("RL04 the email goes from the app's mailbox to itself, its body the v1 format the server reads: header, sender, time, channel, the HMAC signature, then the text unchanged",
            mail.startsWith("From: <relay.test@example.com>\r\nTo: <relay.test@example.com>\r\n") && mail.contains("Content-Transfer-Encoding: base64")
                && body.equals("FIVEHOURS-RELAY 1\nsender: AlRajhiBank\nreceived: 2026-11-13T09:12:00+03:00\nchannel: sms\nsignature: " + expectSig + "\n---\n" + text + "\n")
                && text.contains("٤٥٠") && !text.endsWith("\n"), body);

        // RL05 sending: a fake mail server; down, then up; a refused password keeps everything
        AtomicInteger accepted = new AtomicInteger();
        List<String> received = Collections.synchronizedList(new ArrayList<>());
        Relayer.Result down = r.flush(c, Smtp.forTest("127.0.0.1", 1, c.mailbox, "pw", null));
        int afterDown = box.size();
        try (FakeSmtp srv = new FakeSmtp("app-password", accepted, received)) {
            Relayer.Result wrong = r.flush(c, Smtp.forTest("127.0.0.1", srv.port(), c.mailbox, "wrong", null));
            int afterWrong = box.size();
            r.accept(c, KEY, "Alrajhi", SAMPLE_AT + 60_000, "notification", "تم خصم 9.60 ر.س رسوم نقاط البيع من حساب **4321\n.\n.hidden");
            Relayer.Result ok = r.flush(c, Smtp.forTest("127.0.0.1", srv.port(), c.mailbox, "app-password", null));
            check("RL05 with no internet the message waits; a refused password is told apart and keeps it; when the server takes it the outbox is emptied (a line that starts with a dot arrives whole)",
                down.error != null && !down.refused() && afterDown == 1 && wrong.refused() && afterWrong == 1 && ok.error == null && ok.sent == 2 && box.size() == 0
                    && accepted.get() == 2 && received.stream().anyMatch(m -> m.contains("Subject: FIVEHOURS-RELAY"))
                    && received.stream().anyMatch(m -> new String(Base64.getMimeDecoder().decode(m.substring(m.indexOf("\r\n\r\n") + 4)), StandardCharsets.UTF_8).endsWith("\n.\n.hidden\n")),
                "down=" + down.error + " wrong=" + wrong.error + " ok=" + ok.error + " sent=" + ok.sent + " left=" + box.size());
        }

        // RL07 the mail server's certificate must be for its name before the password goes
        File ks = new File(work, "tls");
        ks.mkdirs();
        SSLContext evil = tlsContext(ks, "evil", "CN=evil.example", "dns:evil.example");
        SSLContext good = tlsContext(ks, "good", "CN=localhost", "dns:localhost");
        List<String> evilGot = Collections.synchronizedList(new ArrayList<>());
        boolean evilRefused = false, goodOk = false;
        try (FakeSmtp srv = new FakeSmtp("app-password", new AtomicInteger(), evilGot, evil.getServerSocketFactory(), null)) {
            Outbox ob = new Outbox(new File(work, "tls-out"));
            new Relayer(ob).accept(c, KEY, "AlRajhiBank", SAMPLE_AT, "sms", SAMPLE_TEXT);
            Relayer.Result res = new Relayer(ob).flush(c, Smtp.forTest("localhost", srv.port(), c.mailbox, "app-password", evil.getSocketFactory()));
            evilRefused = res.error != null && !res.refused() && ob.size() == 1 && srv.passwords.isEmpty();
        }
        try (FakeSmtp srv = new FakeSmtp("app-password", new AtomicInteger(), new ArrayList<>(), good.getServerSocketFactory(), null)) {
            Outbox ob = new Outbox(new File(work, "tls-ok"));
            new Relayer(ob).accept(c, KEY, "AlRajhiBank", SAMPLE_AT, "sms", SAMPLE_TEXT);
            Relayer.Result res = new Relayer(ob).flush(c, Smtp.forTest("localhost", srv.port(), c.mailbox, "app-password", good.getSocketFactory()));
            goodOk = res.error == null && res.sent == 1 && ob.size() == 0;
        }
        check("RL07 over TLS the password goes only to a server whose certificate is for its name: a certificate for another name gets no login and the message waits",
            evilRefused && goodOk, "evil=" + evilRefused + " good=" + goodOk);

        // RL08 one message the server refuses does not hold the others back, and none is sent twice
        AtomicInteger acc8 = new AtomicInteger();
        List<String> got8 = Collections.synchronizedList(new ArrayList<>());
        try (FakeSmtp srv = new FakeSmtp("app-password", acc8, got8, null, "4444")) {
            Outbox ob = new Outbox(new File(work, "hol"));
            Relayer r8 = new Relayer(ob);
            r8.accept(c, KEY, "AlRajhiBank", SAMPLE_AT, "sms", "حوالة 1 إلى 605****4321");
            r8.accept(c, KEY, "AlRajhiBank", SAMPLE_AT + 1000, "sms", "حوالة 2 إلى 605****4321 4444");
            r8.accept(c, KEY, "AlRajhiBank", SAMPLE_AT + 2000, "sms", "حوالة 3 إلى 605****4321");
            Relayer.Result res = r8.flush(c, Smtp.forTest("127.0.0.1", srv.port(), c.mailbox, "app-password", null));
            Relayer.Result again = r8.flush(c, Smtp.forTest("127.0.0.1", srv.port(), c.mailbox, "app-password", null));
            check("RL08 a message the mail server refuses is set aside and the others are sent once each; the outbox is not blocked",
                res.error == null && res.sent == 2 && res.setAside == 1 && ob.size() == 0 && ob.setAsideCount() == 1 && acc8.get() == 2 && again.sent == 0,
                "sent=" + res.sent + " aside=" + res.setAside + " left=" + ob.size() + " accepted=" + acc8.get() + " err=" + res.error);
        }

        // RL09 a refusal of the session (the daily sending limit) keeps every message queued for the next try
        try (FakeSmtp srv = new FakeSmtp("app-password", new AtomicInteger(), new ArrayList<>(), null, null)) {
            srv.mailFromReply = "550 5.4.5 Daily user sending limit exceeded";
            Outbox ob = new Outbox(new File(work, "quota"));
            Relayer r9 = new Relayer(ob);
            for (int i = 0; i < 5; i++) r9.accept(c, KEY, "AlRajhiBank", SAMPLE_AT + i * 1000L, "sms", "حوالة " + i + " إلى 605****4321");
            Relayer.Result res = r9.flush(c, Smtp.forTest("127.0.0.1", srv.port(), c.mailbox, "app-password", null));
            check("RL09 a refusal before any message's text (the daily sending limit) stops the round and keeps all five queued; nothing is set aside",
                res.error != null && res.sent == 0 && res.setAside == 0 && ob.size() == 5 && ob.setAsideCount() == 0,
                "sent=" + res.sent + " aside=" + res.setAside + " left=" + ob.size() + " err=" + res.error);
        }

        // RL06 the sample the server-side checks read
        Outbox sampleBox = new Outbox(new File(work, "sample"));
        new Relayer(sampleBox).accept(c, KEY, "AlRajhiBank", SAMPLE_AT, "sms", SAMPLE_TEXT);
        String sample = Outbox.read(sampleBox.files().get(0)).replaceAll("(?m)^Date: .*\r\n", "Date: Fri, 13 Nov 2026 06:12:00 +0000\r\n");
        if (args.length > 0) {
            File f = new File(args[0]);
            boolean same = f.exists() && new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8).equals(sample);
            if (args.length > 1 && args[1].equals("--write")) { Files.write(f.toPath(), sample.getBytes(StandardCharsets.UTF_8)); same = true; }
            check("RL06 the sample email kept in the repository is exactly what the app writes (the server-side checks read that one)", same, f.getPath());
        }

        System.out.println("passed " + passed + ", failed " + failed);
        System.exit(failed == 0 ? 0 : 1);
    }

    /** a mail server that takes AUTH LOGIN with one password and keeps what it receives */
    static final class FakeSmtp implements AutoCloseable {
        private final ServerSocket ss;
        private final Thread t;
        final List<String> passwords = Collections.synchronizedList(new ArrayList<>());
        volatile String mailFromReply = null;

        FakeSmtp(String password, AtomicInteger accepted, List<String> received) throws Exception { this(password, accepted, received, null, null); }

        /** tls: a TLS server (465 style); refuse: a message whose text has it is refused with 552 */
        FakeSmtp(String password, AtomicInteger accepted, List<String> received, SSLServerSocketFactory tls, String refuse) throws Exception {
            ss = tls == null ? new ServerSocket(0) : tls.createServerSocket(0);
            t = new Thread(() -> {
                while (!ss.isClosed()) {
                    try (Socket s = ss.accept()) { session(s, password, accepted, received, passwords, refuse, mailFromReply); } catch (Exception ignored) { }
                }
            });
            t.setDaemon(true);
            t.start();
        }

        int port() { return ss.getLocalPort(); }

        static void session(Socket s, String password, AtomicInteger accepted, List<String> received, List<String> passwords, String refuse, String mailFromReply) throws Exception {
            BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
            OutputStream out = s.getOutputStream();
            java.util.function.Consumer<String> say = l -> { try { out.write((l + "\r\n").getBytes(StandardCharsets.UTF_8)); out.flush(); } catch (Exception e) { throw new RuntimeException(e); } };
            say.accept("220 fake ready");
            String line; int step = 0;
            while ((line = in.readLine()) != null) {
                if (line.startsWith("EHLO")) { say.accept("250-fake"); say.accept("250 AUTH LOGIN"); }
                else if (line.equals("AUTH LOGIN")) { say.accept("334 VXNlcm5hbWU6"); step = 1; }
                else if (step == 1) { say.accept("334 UGFzc3dvcmQ6"); step = 2; }
                else if (step == 2) {
                    String pw = new String(Base64.getDecoder().decode(line), StandardCharsets.UTF_8);
                    passwords.add(pw);
                    if (pw.equals(password)) { say.accept("235 ok"); step = 3; } else { say.accept("535 5.7.8 bad credentials"); return; }
                }
                else if (line.startsWith("MAIL FROM") && mailFromReply != null) say.accept(mailFromReply);
                else if (line.startsWith("MAIL FROM") || line.startsWith("RCPT TO")) say.accept(step == 3 ? "250 ok" : "530 auth first");
                else if (line.equals("DATA")) {
                    say.accept("354 go");
                    StringBuilder m = new StringBuilder(); String d;
                    while ((d = in.readLine()) != null && !d.equals(".")) m.append(d.startsWith("..") ? d.substring(1) : d).append("\r\n");
                    String text = m.toString();
                    String plain = text.contains("\r\n\r\n") ? new String(Base64.getMimeDecoder().decode(text.substring(text.indexOf("\r\n\r\n") + 4)), StandardCharsets.UTF_8) : "";
                    if (refuse != null && plain.contains(refuse)) { say.accept("552 5.3.4 message refused"); continue; }
                    received.add(text); accepted.incrementAndGet(); say.accept("250 queued");
                }
                else if (line.equals("RSET")) say.accept("250 reset");
                else if (line.equals("QUIT")) { say.accept("221 bye"); return; }
                else say.accept("500 what");
            }
        }

        @Override public void close() throws Exception { ss.close(); }
    }

    /** a key pair and certificate (keytool, as the JDK ships it) for a test TLS server, and a client that trusts it */
    static SSLContext tlsContext(File dir, String name, String dname, String san) throws Exception {
        File store = new File(dir, name + ".p12");
        String keytool = new File(System.getProperty("java.home"), "bin/keytool").getPath();
        Process p = new ProcessBuilder(keytool, "-genkeypair", "-alias", name, "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
            "-dname", dname, "-ext", "SAN=" + san, "-storetype", "PKCS12", "-keystore", store.getPath(), "-storepass", "changeit", "-keypass", "changeit")
            .redirectErrorStream(true).start();
        p.getInputStream().readAllBytes();
        if (p.waitFor() != 0) throw new IllegalStateException("keytool");
        KeyStore ks = KeyStore.getInstance("PKCS12");
        try (java.io.FileInputStream in = new java.io.FileInputStream(store)) { ks.load(in, "changeit".toCharArray()); }
        KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(ks, "changeit".toCharArray());
        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(ks);
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(kmf.getKeyManagers(), tmf.getTrustManagers(), null);
        return ctx;
    }

    static { Arrays.asList(Date.class); }
}
