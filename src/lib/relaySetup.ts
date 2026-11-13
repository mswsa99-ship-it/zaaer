/**
 * The setup text of the phone app (A9), made from «بريد البنك»: the app's mailbox, the mail server it sends through,
 * the bank senders it may relay, the rule of each branch's bank account, and — only right after a new key was made —
 * the relay key. The app reads it as it is (android/…/core/Config.java). The mailbox password is never in it.
 */
import type { BankMailSettings } from "./api";

/** where the phone sends from: the SMTP server of the mailbox's provider (imap.x → smtp.x, port 465) */
export function smtpFor(imapHost: string): string {
  const h = imapHost.trim().toLowerCase();
  return (h.startsWith("imap.") ? "smtp." + h.slice(5) : h) + ":465";
}

export type SetupProblem = "mailbox" | "accounts" | null;

export function setupProblem(s: Pick<BankMailSettings, "mailbox_address" | "accounts">): SetupProblem {
  if (!s.mailbox_address) return "mailbox";
  if (!s.accounts.some((a) => a.prefix && a.suffix)) return "accounts";
  return null;
}

export function setupText(s: Pick<BankMailSettings, "mailbox_address" | "imap_host" | "allowed_senders" | "accounts">, key?: string | null): string {
  const lines = ["FIVEHOURS-SETUP 1", `mailbox: ${s.mailbox_address ?? ""}`, `smtp: ${smtpFor(s.imap_host)}`, `senders: ${s.allowed_senders.join(", ")}`];
  for (const a of s.accounts) if (a.prefix && a.suffix) lines.push(`account: ${a.prefix}…${a.suffix}`);
  if (key) lines.push(`key: ${key}`);
  return lines.join("\n") + "\n";
}
