package sa.fivehours.relay.core;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * What the app needs, all set by the owner: the app's mailbox (it sends from it to itself), its mail server, the bank
 * senders it may relay, the rule of each branch's bank account, and the relay key. Everything but the mailbox
 * password comes in one setup text that «بريد البنك» in the system makes:
 * <pre>
 *   FIVEHOURS-SETUP 1
 *   mailbox: relay@example.com
 *   user: relay@example.com   (the login, when it is not the address)
 *   smtp: smtp.gmail.com:465
 *   senders: AlRajhiBank, Alrajhi, الراجحي
 *   account: 605…4321
 *   account: 608…7788
 *   key: 3f…                (only when a new key was made; otherwise the phone keeps its key)
 * </pre>
 * The password is typed on the phone and never leaves it except to the mail server.
 */
public final class Config {
    public final String mailbox;
    public final String user;     // the mailbox's login (its address unless the provider says otherwise)
    public final String smtpHost;
    public final int smtpPort;
    public final List<String> senders;
    public final List<AccountRules.Rule> accounts;
    public final String key;   // null: keep the one the phone has

    public Config(String mailbox, String user, String smtpHost, int smtpPort, List<String> senders, List<AccountRules.Rule> accounts, String key) {
        this.mailbox = mailbox; this.user = user == null || user.isEmpty() ? mailbox : user; this.smtpHost = smtpHost; this.smtpPort = smtpPort;
        this.senders = Collections.unmodifiableList(new ArrayList<>(senders));
        this.accounts = Collections.unmodifiableList(new ArrayList<>(accounts));
        this.key = key;
    }

    public static final class Invalid extends IllegalArgumentException {
        private static final long serialVersionUID = 1L;
        public final String field;
        Invalid(String field) { super(field); this.field = field; }
    }

    public static Config parse(String text) {
        String[] lines = (text == null ? "" : text).replace("\r\n", "\n").trim().split("\n");
        if (lines.length == 0 || !lines[0].trim().equals("FIVEHOURS-SETUP 1")) throw new Invalid("header");
        String mailbox = null, user = null, host = null, key = null; int port = 0;
        List<String> senders = new ArrayList<>(); List<AccountRules.Rule> accounts = new ArrayList<>();
        for (int i = 1; i < lines.length; i++) {
            String line = lines[i].trim();
            if (line.isEmpty()) continue;
            int c = line.indexOf(':');
            if (c <= 0) throw new Invalid("line");
            String k = line.substring(0, c).trim().toLowerCase(Locale.ROOT), v = line.substring(c + 1).trim();
            switch (k) {
                case "mailbox":
                    if (!v.matches("[^@\\s]+@[^@\\s]+\\.[^@\\s]+")) throw new Invalid("mailbox");
                    mailbox = v.toLowerCase(Locale.ROOT); break;
                case "user":
                    if (v.isEmpty() || v.length() > 200 || v.matches(".*\\s.*")) throw new Invalid("user");
                    user = v; break;
                case "smtp": {
                    int p = v.lastIndexOf(':');
                    if (p <= 0) throw new Invalid("smtp");
                    host = v.substring(0, p).trim().toLowerCase(Locale.ROOT);
                    try { port = Integer.parseInt(v.substring(p + 1).trim()); } catch (NumberFormatException e) { throw new Invalid("smtp"); }
                    if (!host.matches("[a-z0-9.-]{3,100}") || port < 1 || port > 65535) throw new Invalid("smtp");
                    break;
                }
                case "senders":
                    for (String s : v.split(",")) if (!s.trim().isEmpty()) senders.add(s.trim());
                    break;
                case "account":
                    try { accounts.add(AccountRules.Rule.parse(v)); } catch (IllegalArgumentException e) { throw new Invalid("account"); }
                    break;
                case "key":
                    if (!v.matches("[0-9A-Za-z]{16,128}")) throw new Invalid("key");
                    key = v; break;
                default: // a later field this version does not know is left alone
            }
        }
        if (mailbox == null) throw new Invalid("mailbox");
        if (host == null) throw new Invalid("smtp");
        if (senders.isEmpty()) throw new Invalid("senders");
        if (accounts.isEmpty()) throw new Invalid("account");
        return new Config(mailbox, user, host, port, senders, accounts, key);
    }

    /** the setup text again (without the key), to keep and show */
    public String format() {
        StringBuilder b = new StringBuilder("FIVEHOURS-SETUP 1\n");
        b.append("mailbox: ").append(mailbox).append('\n');
        if (!user.equals(mailbox)) b.append("user: ").append(user).append('\n');
        b.append("smtp: ").append(smtpHost).append(':').append(smtpPort).append('\n');
        b.append("senders: ").append(String.join(", ", senders)).append('\n');
        for (AccountRules.Rule r : accounts) b.append("account: ").append(r).append('\n');
        return b.toString();
    }

    /** a sender the owner allowed (as the server compares: case aside) */
    public boolean allows(String sender) {
        String s = Relay.oneLine(sender);
        for (String a : senders) if (a.equalsIgnoreCase(s)) return true;
        return false;
    }
}
