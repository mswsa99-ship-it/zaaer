package sa.fivehours.relay.core;

/** Digits as the bank writes them (Arabic-Indic or Persian) → 0–9, the Arabic decimal and thousands marks, one space
 *  for runs of spaces, tabs and no-break spaces: fn_bank_normalize of migration 0066. */
public final class Digits {
    private Digits() {}

    public static String normalize(String s) {
        if (s == null) return "";
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c >= '٠' && c <= '٩') b.append((char) ('0' + (c - '٠')));
            else if (c >= '۰' && c <= '۹') b.append((char) ('0' + (c - '۰')));
            else if (c == '٫') b.append('.');
            else if (c == '٬') b.append(',');
            else b.append(c);
        }
        return b.toString().replaceAll("[ \\t\\u00A0]+", " ");
    }
}
