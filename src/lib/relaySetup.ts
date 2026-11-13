/**
 * The setup text of the phone app (A9), made from «بريد البنك»: the app's mailbox, the mail server it sends through,
 * the bank senders it may relay, the rule of each branch's bank account, and — only right after a new key was made —
 * the relay key. The app reads it as it is (android/…/core/Config.java). The mailbox password is never in it.
 */
import type { BankMailSettings } from "./api";

/** the sending servers of the common providers whose name is not imap.x → smtp.x, or that send on 587 (STARTTLS) */
const KNOWN: Record<string, string> = {
  "outlook.office365.com": "smtp.office365.com:587",
  "imap-mail.outlook.com": "smtp-mail.outlook.com:587",
  "imap.mail.me.com": "smtp.mail.me.com:587",
};

/** where the phone sends from: the SMTP server of the mailbox's provider (imap.x → smtp.x, port 465) */
export function smtpFor(imapHost: string): string {
  const h = imapHost.trim().toLowerCase();
  if (KNOWN[h]) return KNOWN[h];
  return (h.startsWith("imap.") ? "smtp." + h.slice(5) : h) + ":465";
}

export type SetupProblem = "mailbox" | "accounts" | null;

export function setupProblem(s: Pick<BankMailSettings, "mailbox_address" | "accounts">): SetupProblem {
  if (!s.mailbox_address) return "mailbox";
  if (!s.accounts.some((a) => a.prefix && a.suffix)) return "accounts";
  return null;
}

export function setupText(s: Pick<BankMailSettings, "mailbox_address" | "imap_user" | "imap_host" | "allowed_senders" | "accounts">, key?: string | null): string {
  const lines = ["FIVEHOURS-SETUP 1", `mailbox: ${s.mailbox_address ?? ""}`];
  // the login, when it is not the address itself (the phone signs in to send with the same login the system reads with)
  if (s.imap_user && s.imap_user.toLowerCase() !== (s.mailbox_address ?? "").toLowerCase()) lines.push(`user: ${s.imap_user}`);
  lines.push(`smtp: ${smtpFor(s.imap_host)}`, `senders: ${s.allowed_senders.join(", ")}`);
  for (const a of s.accounts) if (a.prefix && a.suffix) lines.push(`account: ${a.prefix}…${a.suffix}`);
  if (key) lines.push(`key: ${key}`);
  return lines.join("\n") + "\n";
}
