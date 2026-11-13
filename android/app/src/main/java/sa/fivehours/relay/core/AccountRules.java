package sa.fivehours.relay.core;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Which messages the phone may relay (plan A9, decision of 27 October): only a message that carries an account number
 * starting and ending with the digits of one of the branches' bank accounts. The same reading as the server
 * (migration 0066: fn_bank_normalize, the token pattern of fn_bank_extract, fn_bank_account_fits), so the phone never
 * relays what the server would not tie to an account, and never drops what it would.
 */
public final class AccountRules {
    private AccountRules() {}

    /** one account's rule: its number starts with {@code prefix} and ends with {@code suffix} (2–6 digits each) */
    public static final class Rule {
        public final String prefix;
        public final String suffix;

        public Rule(String prefix, String suffix) {
            if (prefix == null || !prefix.matches("[0-9]{2,6}") || suffix == null || !suffix.matches("[0-9]{2,6}")) {
                throw new IllegalArgumentException("rule");
            }
            this.prefix = prefix;
            this.suffix = suffix;
        }

        /** "605…4321" (or 605...4321, 605-4321, 605 4321) */
        public static Rule parse(String s) {
            Matcher m = Pattern.compile("^\\s*([0-9]{2,6})\\s*(?:…|\\.{2,3}|-|\\s)\\s*([0-9]{2,6})\\s*$").matcher(Digits.normalize(s));
            if (!m.matches()) throw new IllegalArgumentException("rule");
            return new Rule(m.group(1), m.group(2));
        }

        @Override public String toString() { return prefix + "…" + suffix; }
    }

    // a number standing alone: masked in the middle (605****192), only its end (**192), or all of it (10+ digits)
    private static final Pattern TOKEN = Pattern.compile(
        "(?<![0-9A-Za-z])([0-9]{2,}[*xX•…]+[0-9]{2,}|[*xX•…]+[0-9]{3,}|[0-9]{10,})(?![0-9A-Za-z])");

    /** the account-like numbers of a message, in order; a phone number (05…, 9665…, 00966…) is not one */
    public static List<String> tokens(String text) {
        List<String> out = new ArrayList<>();
        Matcher m = TOKEN.matcher(Digits.normalize(text));
        while (m.find()) {
            String tok = m.group(1);
            if (tok.matches("[0-9]+") && (tok.startsWith("05") || tok.startsWith("9665") || tok.startsWith("00966"))) continue;
            out.add(tok);
        }
        return out;
    }

    /** fn_bank_account_fits: does a token of a message fit an account that starts with prefix and ends with suffix? */
    public static boolean fits(String tok, String prefix, String suffix) {
        if (tok.matches("[0-9]+")) return tok.startsWith(prefix) && tok.endsWith(suffix);
        Matcher h = Pattern.compile("^([0-9]*)").matcher(tok);
        String head = h.find() ? h.group(1) : "";
        Matcher t = Pattern.compile("([0-9]+)$").matcher(tok);
        String tail = t.find() ? t.group(1) : null;
        if (tail == null) return false;
        boolean agreeEnd = tail.length() >= suffix.length() ? tail.endsWith(suffix) : suffix.endsWith(tail);
        if (!agreeEnd) return false;
        if (head.isEmpty()) return tail.length() >= 3;
        int k = Math.min(head.length(), prefix.length());
        return head.substring(0, k).equals(prefix.substring(0, k));
    }

    /** does the message carry the number of one of the accounts? */
    public static boolean matches(String text, List<Rule> rules) {
        if (text == null || rules == null || rules.isEmpty()) return false;
        for (String tok : tokens(text)) {
            for (Rule r : rules) if (fits(tok, r.prefix, r.suffix)) return true;
        }
        return false;
    }
}
