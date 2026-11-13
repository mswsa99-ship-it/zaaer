package sa.fivehours.relay.core;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * Sends one email by SMTP: port 465 (TLS from the start) or 587 (STARTTLS), AUTH LOGIN with the mailbox and its app
 * password. No library: the phone app has no dependency at all. A refusal of the password or of the message is
 * {@link Refused} (sending again will not help until the settings change); anything else — no network, a timeout, a
 * server busy (4xx) — is an IOException, and the message stays in the outbox for the next try.
 */
public final class Smtp {
    public static final class Refused extends IOException {
        private static final long serialVersionUID = 1L;
        public final int code;
        Refused(int code, String text) { super(code + " " + text); this.code = code; }
    }

    /** how a connection is opened (tests use a plain socket to a local server) */
    public interface Connector { Socket open(String host, int port) throws IOException; }

    public static final Connector TLS = (host, port) -> {
        Socket s = SSLSocketFactory.getDefault().createSocket();
        s.connect(new InetSocketAddress(host, port), 20_000);
        s.setSoTimeout(30_000);
        if (s instanceof SSLSocket) ((SSLSocket) s).startHandshake();
        return s;
    };
    public static final Connector PLAIN = (host, port) -> {
        Socket s = new Socket();
        s.connect(new InetSocketAddress(host, port), 20_000);
        s.setSoTimeout(30_000);
        return s;
    };

    private final String host;
    private final int port;
    private final String user;
    private final String password;
    private final Connector connector;
    private final boolean startTls;

    public Smtp(String host, int port, String user, String password, Connector connector, boolean startTls) {
        this.host = host; this.port = port; this.user = user; this.password = password; this.connector = connector; this.startTls = startTls;
    }

    /** the real server: 465 → TLS from the start, any other port → STARTTLS */
    public static Smtp forServer(String host, int port, String user, String password) {
        return port == 465 ? new Smtp(host, port, user, password, TLS, false) : new Smtp(host, port, user, password, PLAIN, true);
    }

    private Socket sock;
    private BufferedReader in;
    private OutputStream out;

    /** sends each message (whole RFC 5322 text) in one session; returns how many were accepted before a failure */
    public int send(String from, List<String> messages) throws IOException {
        int sent = 0;
        sock = connector.open(host, port);
        try {
            attach();
            expect(220);
            ehlo();
            if (startTls) {
                cmd("STARTTLS", 220);
                SSLSocket tls = (SSLSocket) ((SSLSocketFactory) SSLSocketFactory.getDefault()).createSocket(sock, host, port, true);
                tls.startHandshake();
                sock = tls;
                attach();
                ehlo();
            }
            cmd("AUTH LOGIN", 334);
            cmd(b64(user), 334);
            cmdSecret(b64(password), 235);
            for (String m : messages) {
                cmd("MAIL FROM:<" + from + ">", 250);
                cmd("RCPT TO:<" + from + ">", 250, 251);
                cmd("DATA", 354);
                write(dotStuff(m) + ".\r\n");
                expect(250);
                sent++;
            }
            try { cmd("QUIT", 221); } catch (IOException ignored) { /* already delivered */ }
            return sent;
        } finally {
            try { sock.close(); } catch (IOException ignored) { }
        }
    }

    private void attach() throws IOException {
        in = new BufferedReader(new InputStreamReader(sock.getInputStream(), StandardCharsets.US_ASCII));
        out = sock.getOutputStream();
    }

    private void ehlo() throws IOException { cmd("EHLO fivehours-relay", 250); }

    private static String b64(String s) { return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8)); }

    static String dotStuff(String m) {
        String t = m.replace("\r\n", "\n").replace("\n", "\r\n");
        if (!t.endsWith("\r\n")) t += "\r\n";
        StringBuilder b = new StringBuilder(t.length() + 16);
        for (String line : t.split("\r\n", -1)) {
            if (b.length() > 0) b.append("\r\n");
            b.append(line.startsWith(".") ? "." + line : line);
        }
        return b.toString();
    }

    private void write(String s) throws IOException { out.write(s.getBytes(StandardCharsets.UTF_8)); out.flush(); }

    private void cmd(String line, int... ok) throws IOException { write(line + "\r\n"); expect(ok); }

    /** the password line: a refusal is never echoed with it */
    private void cmdSecret(String line, int ok) throws IOException { write(line + "\r\n"); expect(ok); }

    private void expect(int... ok) throws IOException {
        String line; int code; StringBuilder text = new StringBuilder();
        do {
            line = in.readLine();
            if (line == null || line.length() < 3) throw new IOException("SMTP connection closed");
            code = Integer.parseInt(line.substring(0, 3));
            text.append(line.length() > 4 ? line.substring(4) : "").append(' ');
        } while (line.length() > 3 && line.charAt(3) == '-');
        for (int c : ok) if (c == code) return;
        if (code >= 500) throw new Refused(code, text.toString().trim());
        throw new IOException("SMTP " + code + " " + text.toString().trim());
    }
}
