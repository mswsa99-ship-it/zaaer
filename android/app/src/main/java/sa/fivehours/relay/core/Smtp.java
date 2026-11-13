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
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * Sends emails by SMTP: port 465 (TLS from the start) or another port with STARTTLS; AUTH LOGIN with the mailbox's
 * login and its app password. The server's certificate must be valid for the server's name (checked before the
 * password is sent). No library: the phone app has no dependency at all.
 * Failures: the login refused → {@link Refused} with {@code login} true (nothing is sent until the settings change);
 * one message's content refused (5xx after its text) → that message only, the others go on; a refusal before the text
 * (a daily limit, the sender) stops the round like anything else (no network, a timeout, a busy server 4xx): an IOException, and what was not accepted waits for the next try.
 */
public final class Smtp {
    public static final class Refused extends IOException {
        private static final long serialVersionUID = 1L;
        public final int code;
        public final boolean login;
        Refused(int code, String text, boolean login) { super(code + " " + text); this.code = code; this.login = login; }
    }

    /** what happened to each message offered */
    public interface Listener {
        void accepted(int index) throws IOException;
        void refused(int index, Refused why) throws IOException;
    }

    private final String host;
    private final int port;
    private final String user;
    private final String password;
    private final SSLSocketFactory tls;
    private final boolean implicitTls;
    private final boolean startTls;

    Smtp(String host, int port, String user, String password, SSLSocketFactory tls, boolean implicitTls, boolean startTls) {
        this.host = host; this.port = port; this.user = user; this.password = password; this.tls = tls;
        this.implicitTls = implicitTls; this.startTls = startTls;
    }

    /** the real server: 465 → TLS from the start, any other port → STARTTLS (never a login in clear) */
    public static Smtp forServer(String host, int port, String user, String password) {
        SSLSocketFactory f = (SSLSocketFactory) SSLSocketFactory.getDefault();
        return port == 465 ? new Smtp(host, port, user, password, f, true, false) : new Smtp(host, port, user, password, f, false, true);
    }

    /** tests: a given TLS trust (465 style), or a plain local server (no TLS at all) */
    static Smtp forTest(String host, int port, String user, String password, SSLSocketFactory tls) {
        return tls == null ? new Smtp(host, port, user, password, null, false, false) : new Smtp(host, port, user, password, tls, true, false);
    }

    private Socket sock;
    private BufferedReader in;
    private OutputStream out;

    /** TLS over the connection, named for the host (SNI) and checking that the certificate is for that name (Java and
     *  Android do not check the name by default) */
    private SSLSocket secure(Socket over) throws IOException {
        SSLSocket s = (SSLSocket) tls.createSocket(over, host, port, true);
        s.setSoTimeout(30_000);
        SSLParameters p = s.getSSLParameters();
        p.setEndpointIdentificationAlgorithm("HTTPS");
        s.setSSLParameters(p);
        s.startHandshake();
        return s;
    }

    /** sends each message (its whole RFC 5322 text) in one session, telling the listener after each one */
    public void send(String from, List<String> messages, Listener l) throws IOException {
        sock = new Socket();
        sock.connect(new InetSocketAddress(host, port), 20_000);
        sock.setSoTimeout(30_000);
        if (implicitTls) sock = secure(sock);
        try {
            attach();
            expect(false, 220);
            ehlo();
            if (startTls) {
                cmd(false, "STARTTLS", 220);
                sock = secure(sock);
                attach();
                ehlo();
            }
            cmd(true, "AUTH LOGIN", 334);
            cmd(true, b64(user), 334);
            cmd(true, b64(password), 235);
            for (int i = 0; i < messages.size(); i++) {
                // a refusal before the content (the sender, the recipient, a daily limit) is about the session, not this
                // message: it stops the round and everything stays queued
                cmd(false, "MAIL FROM:<" + from + ">", 250);
                cmd(false, "RCPT TO:<" + from + ">", 250, 251);
                cmd(false, "DATA", 354);
                write(dotStuff(messages.get(i)) + ".\r\n");
                try {
                    expect(false, 250);
                } catch (Refused r) {
                    // the content of this one message was refused: it is set aside and the others go on
                    l.refused(i, r);
                    cmd(false, "RSET", 250);
                    continue;
                }
                l.accepted(i);
            }
            try { cmd(false, "QUIT", 221); } catch (IOException ignored) { /* already delivered */ }
        } finally {
            try { sock.close(); } catch (IOException ignored) { }
        }
    }

    private void attach() throws IOException {
        in = new BufferedReader(new InputStreamReader(sock.getInputStream(), StandardCharsets.US_ASCII));
        out = sock.getOutputStream();
    }

    private void ehlo() throws IOException { cmd(false, "EHLO fivehours-relay", 250); }

    private static String b64(String s) { return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8)); }

    static String dotStuff(String m) {
        String t = m.replace("\r\n", "\n").replace("\n", "\r\n");
        if (!t.endsWith("\r\n")) t += "\r\n";
        StringBuilder b = new StringBuilder(t.length() + 16);
        String[] lines = t.split("\r\n", -1);
        for (int i = 0; i < lines.length; i++) {
            if (i > 0) b.append("\r\n");
            b.append(lines[i].startsWith(".") ? "." + lines[i] : lines[i]);
        }
        return b.toString();
    }

    private void write(String s) throws IOException { out.write(s.getBytes(StandardCharsets.UTF_8)); out.flush(); }

    private void cmd(boolean login, String line, int... ok) throws IOException { write(line + "\r\n"); expect(login, ok); }

    /** a refusal never carries the line sent (the password is one) */
    private void expect(boolean login, int... ok) throws IOException {
        String line; int code; StringBuilder text = new StringBuilder();
        do {
            line = in.readLine();
            if (line == null || line.length() < 3) throw new IOException("SMTP connection closed");
            try { code = Integer.parseInt(line.substring(0, 3)); } catch (NumberFormatException e) { throw new IOException("SMTP reply not understood"); }
            text.append(line.length() > 4 ? line.substring(4) : "").append(' ');
        } while (line.length() > 3 && line.charAt(3) == '-');
        for (int c : ok) if (c == code) return;
        if (code >= 500) throw new Refused(code, text.toString().trim(), login);
        throw new IOException("SMTP " + code + " " + text.toString().trim());
    }
}
