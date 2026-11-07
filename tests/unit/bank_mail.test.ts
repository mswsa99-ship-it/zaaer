/**
 * BK20–BK24: the bank mailbox reader (A6) without a network — the MIME reader, the IMAP client against a scripted server,
 * and one whole reading against a fake database: every message handed whole to fn_bank_ingest, the last one read
 * remembered, nothing marked read, the password never in the error kept for the owner.
 */
import { describe, it, expect } from "vitest";
import { readMail, decodeWords } from "../../supabase/functions/_shared/mime";
import { Imap, quote, type Wire } from "../../supabase/functions/_shared/imap";
import { pollMailbox } from "../../supabase/functions/_shared/bank_mail";

const latin1 = (s: string) => Array.from(new TextEncoder().encode(s), (b) => String.fromCharCode(b)).join("");
const b64 = (s: string) => btoa(latin1(s));
const RELAY = "FIVEHOURS-RELAY 1\nsender: AlRajhiBank\nreceived: 2026-11-07T21:00:00+03:00\nchannel: sms\nsignature: abc\n---\nحوالة واردة\nمبلغ: 100 SAR";

function mail(body: string, extra = ""): string {
  return latin1(`From: Bank Relay <relay.test@example.com>\r\nTo: relay.test@example.com\r\nMessage-ID: <m1@example.com>\r\nDate: Sat, 07 Nov 2026 18:00:00 +0000\r\n` +
    `Subject: =?UTF-8?B?${b64("رسالة بنكية")}?=\r\n${extra}MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n${b64(body)}\r\n`);
}

/** a scripted IMAP server: answers each tagged command from the table, records what it was asked */
function server(messages: Record<number, string>, opts: { validity?: number; failLogin?: boolean } = {}) {
  const asked: string[] = []; const out: string[] = ["* OK IMAP ready\r\n"];
  const wire: Wire = {
    async read() { const s = out.shift(); return s === undefined ? null : Uint8Array.from(s, (c) => c.charCodeAt(0)); },
    async write(d) {
      const line = String.fromCharCode(...d).replace(/\r\n$/, ""); asked.push(line);
      const [tag, cmd, ...rest] = line.split(" ");
      const up = cmd.toUpperCase();
      if (up === "LOGIN") out.push(opts.failLogin ? `${tag} NO [AUTHENTICATIONFAILED] Invalid credentials\r\n` : `${tag} OK logged in\r\n`);
      else if (up === "EXAMINE") out.push(`* 3 EXISTS\r\n* OK [UIDVALIDITY ${opts.validity ?? 9}] UIDs valid\r\n${tag} OK [READ-ONLY] done\r\n`);
      else if (up === "UID" && rest[0] === "SEARCH") {
        const from = Number(rest[2].split(":")[0]);
        const uids = Object.keys(messages).map(Number).filter((u) => u >= from);
        out.push(`* SEARCH ${(uids.length ? uids : [Math.max(...Object.keys(messages).map(Number))]).join(" ")}\r\n${tag} OK search done\r\n`);
      } else if (up === "UID" && rest[0] === "FETCH") {
        const m = messages[Number(rest[1])];
        out.push(`* 1 FETCH (UID ${rest[1]} BODY[] {${m.length}}\r\n${m})\r\n${tag} OK fetch done\r\n`);
      } else if (up === "LOGOUT") out.push(`* BYE\r\n${tag} OK bye\r\n`);
      else out.push(`${tag} BAD unknown\r\n`);
    },
    close() { /* nothing */ },
  };
  return { wire, asked };
}

describe("bank mailbox (A6)", () => {
  it("BK20 the MIME reader: sender, Message-ID, date, an encoded subject and a base64 UTF-8 body come back as written", () => {
    const m = readMail(mail(RELAY));
    expect(m.from).toBe("Bank Relay <relay.test@example.com>");
    expect(m.message_id).toBe("<m1@example.com>");
    expect(m.date).toBe("2026-11-07T18:00:00.000Z");
    expect(m.subject).toBe("رسالة بنكية");
    expect(m.body).toBe(RELAY);
  });

  it("BK21 the MIME reader: the text part of a multipart mail, quoted-printable, and an encoded word in Q form", () => {
    const qp = latin1(RELAY).replace(/[^\x20-\x7e\n]/g, (c) => "=" + c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")).replace(/\n/g, "\r\n");
    const raw = "From: relay.test@example.com\r\nContent-Type: multipart/alternative; boundary=\"zz\"\r\n\r\n--zz\r\nContent-Type: text/html\r\n\r\n<p>x</p>\r\n" +
      "--zz\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" + qp + "\r\n--zz--\r\n";
    expect(readMail(raw).body).toBe(RELAY);
    expect(decodeWords("=?utf-8?Q?a_b?=")).toBe("a b");
  });

  it("BK22 the IMAP client logs in with a quoted password, opens INBOX read-only, lists only the UIDs after the last one, fetches without marking read", async () => {
    const { wire, asked } = server({ 4: mail(RELAY), 5: mail(RELAY + "\nثانية") });
    const imap = new Imap(wire);
    await imap.greeting();
    await imap.login("relay.test@example.com", 'p"a\\ss');
    expect(await imap.examineInbox()).toBe(9);
    expect(await imap.uidsAfter(4)).toEqual([5]);
    expect(await imap.uidsAfter(5)).toEqual([]);              // n:* returns the last message even when nothing is newer
    const raw = await imap.fetch(5);
    expect(readMail(raw!).body).toBe(RELAY + "\nثانية");
    expect(asked.some((l) => / LOGIN "relay.test@example.com" "p\\"a\\\\ss"$/.test(l))).toBe(true);
    expect(asked.some((l) => / EXAMINE INBOX$/.test(l))).toBe(true);
    expect(asked.some((l) => /BODY\.PEEK\[\]/.test(l))).toBe(true);
    expect(asked.some((l) => /STORE|SELECT|EXPUNGE/.test(l))).toBe(false);
    expect(quote("ب")).toBe('"' + latin1("ب") + '"');
  });

  it("BK23 one reading hands every new message whole to fn_bank_ingest and remembers the last one read", async () => {
    const calls: Array<{ fn: string; args?: Record<string, unknown> }> = [];
    const db = { rpc: async (fn: string, args?: Record<string, unknown>) => {
      calls.push({ fn, args });
      if (fn === "fn_bank_mail_poll_config") return { data: { configured: true, host: "imap.example.com", port: 993, user: "relay.test@example.com", password: "secret-pass", last_uid: 3, uid_validity: 9 }, error: null };
      if (fn === "fn_bank_ingest") return { data: { ok: true, status: "parsed" }, error: null };
      return { data: null, error: null };
    } };
    const s = server({ 3: mail("قديمة"), 4: mail(RELAY), 5: mail(RELAY + "\nثانية") });
    const r = await pollMailbox(db, async () => s.wire);
    expect(r).toMatchObject({ configured: true, fetched: 2 });
    const ingests = calls.filter((c) => c.fn === "fn_bank_ingest").map((c) => (c.args!.p as { body: string; from: string }));
    expect(ingests.map((m) => m.body)).toEqual([RELAY, RELAY + "\nثانية"]);
    expect(ingests[0].from).toBe("Bank Relay <relay.test@example.com>");
    expect(calls.at(-1)).toEqual({ fn: "fn_bank_mail_poll_done", args: { p_last_uid: 5, p_uid_validity: 9, p_error: null } });
  });

  it("BK24 not configured → nothing is read; a refused login is kept as the error without the password, and the last one read stays", async () => {
    const off = { rpc: async () => ({ data: { configured: false }, error: null }) };
    expect(await pollMailbox(off, async () => { throw new Error("must not connect"); })).toEqual({ configured: false, fetched: 0, results: [] });
    const calls: Array<{ fn: string; args?: Record<string, unknown> }> = [];
    const db = { rpc: async (fn: string, args?: Record<string, unknown>) => {
      calls.push({ fn, args });
      if (fn === "fn_bank_mail_poll_config") return { data: { configured: true, host: "h", port: 993, user: "u", password: "secret-pass", last_uid: 7, uid_validity: 9 }, error: null };
      return { data: null, error: null };
    } };
    const s = server({ 8: mail(RELAY) }, { failLogin: true });
    const r = await pollMailbox(db, async () => s.wire);
    expect(r.error).toMatch(/IMAP_LOGIN/);
    const done = calls.at(-1)!;
    expect(done.fn).toBe("fn_bank_mail_poll_done");
    expect(done.args!.p_last_uid).toBe(7);
    expect(String(done.args!.p_error)).not.toContain("secret-pass");
    expect(calls.some((c) => c.fn === "fn_bank_ingest")).toBe(false);
  });

  it("BK25 one email the database cannot take (e.g. a NUL in its text) does not stop the reading: the NUL is taken out, and a refused hand-over is kept as a placeholder and passed", async () => {
    expect(readMail(mail("إيداع\u0000\nمبلغ: 5 SAR")).body).toBe("إيداع\nمبلغ: 5 SAR");
    const calls: Array<{ fn: string; args?: Record<string, unknown> }> = [];
    let first = true;
    const db = { rpc: async (fn: string, args?: Record<string, unknown>) => {
      calls.push({ fn, args });
      if (fn === "fn_bank_mail_poll_config") return { data: { configured: true, host: "h", port: 993, user: "u", password: "p", last_uid: 0, uid_validity: 9 }, error: null };
      if (fn === "fn_bank_ingest") { if (first) { first = false; return { data: null, error: { message: "boom" } }; } return { data: { status: "parsed" }, error: null }; }
      return { data: null, error: null };
    } };
    const s = server({ 1: mail(RELAY), 2: mail(RELAY + "\nثانية") });
    const r = await pollMailbox(db, async () => s.wire);
    expect(r.results.map((x) => x.status)).toEqual(["failed", "parsed"]);
    expect(calls.find((c) => c.fn === "fn_bank_ingest_failed")?.args).toEqual({ p_uid: 1, p_error: "boom" });
    expect(calls.at(-1)?.args?.p_last_uid).toBe(2);
  });
});
