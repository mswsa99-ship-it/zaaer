/**
 * The little IMAP (RFC 9051 / 3501) the bank-mail function needs: log in, open INBOX, list the messages after the last
 * one read (by UID), fetch each one whole without marking it read, log out. It speaks over any byte stream (`Wire`), so
 * the unit tests drive it with a scripted server and the function with Deno.connectTls. Bytes are kept as latin-1
 * strings (one char per byte) so that literal lengths count exactly and the MIME reader decodes charsets itself.
 */
export interface Wire { read(): Promise<Uint8Array | null>; write(data: Uint8Array): Promise<void>; close(): void }
export interface ImapReply { tag: string; status: "OK" | "NO" | "BAD"; text: string; lines: Array<{ line: string; literals: string[] }> }

const toLatin1 = (b: Uint8Array) => { let s = ""; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return s; };
const fromLatin1 = (s: string) => { const b = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff; return b; };
const utf8Latin1 = (s: string) => toLatin1(new TextEncoder().encode(s));

/** an IMAP quoted string (the password may hold any character) */
export function quote(s: string): string {
  return '"' + utf8Latin1(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
}

export class Imap {
  private buf = "";
  private n = 0;
  constructor(private wire: Wire) {}

  private async fill(): Promise<boolean> {
    const chunk = await this.wire.read();
    if (!chunk) return false;
    this.buf += toLatin1(chunk);
    return true;
  }
  private async line(): Promise<string> {
    for (;;) {
      const i = this.buf.indexOf("\r\n");
      if (i >= 0) { const l = this.buf.slice(0, i); this.buf = this.buf.slice(i + 2); return l; }
      if (!(await this.fill())) throw new Error("IMAP_CLOSED");
    }
  }
  private async bytes(n: number): Promise<string> {
    while (this.buf.length < n) if (!(await this.fill())) throw new Error("IMAP_CLOSED");
    const s = this.buf.slice(0, n); this.buf = this.buf.slice(n); return s;
  }
  /** one response line with its literals ({n} at a line's end is followed by n bytes, then the line goes on) */
  private async response(): Promise<{ line: string; literals: string[] }> {
    let line = await this.line(); const literals: string[] = [];
    for (let m = /\{(\d+)\}$/.exec(line); m; m = /\{(\d+)\}$/.exec(line)) {
      literals.push(await this.bytes(Number(m[1])));
      line = line + "\x00" + (await this.line());
    }
    return { line, literals };
  }

  async greeting(): Promise<string> {
    const g = await this.line();
    if (!/^\* (OK|PREAUTH)/i.test(g)) throw new Error("IMAP_GREETING: " + g.slice(0, 80));
    return g;
  }
  async command(cmd: string): Promise<ImapReply> {
    const tag = "z" + (++this.n);
    await this.wire.write(fromLatin1(`${tag} ${cmd}\r\n`));
    const lines: ImapReply["lines"] = [];
    for (;;) {
      const r = await this.response();
      if (r.line.startsWith(tag + " ")) {
        const m = /^\S+ (OK|NO|BAD)\s?(.*)$/i.exec(r.line);
        if (!m) throw new Error("IMAP_PROTOCOL");
        return { tag, status: m[1].toUpperCase() as ImapReply["status"], text: m[2], lines };
      }
      lines.push(r);
    }
  }
  private async ok(cmd: string, what: string): Promise<ImapReply> {
    const r = await this.command(cmd);
    if (r.status !== "OK") throw new Error(`IMAP_${what}: ${r.text.slice(0, 120)}`);
    return r;
  }

  async login(user: string, password: string) { await this.ok(`LOGIN ${quote(user)} ${quote(password)}`, "LOGIN"); }
  /** opens INBOX read-only; its UIDVALIDITY (a new one means the UIDs were renumbered) */
  async examineInbox(): Promise<number | null> {
    const r = await this.ok("EXAMINE INBOX", "SELECT");
    for (const l of r.lines) { const m = /UIDVALIDITY (\d+)/i.exec(l.line); if (m) return Number(m[1]); }
    return null;
  }
  /** the UIDs after `after`, ascending (n:* always includes the last message, so it is filtered) */
  async uidsAfter(after: number): Promise<number[]> {
    const r = await this.ok(`UID SEARCH UID ${after + 1}:*`, "SEARCH");
    const out: number[] = [];
    for (const l of r.lines) if (/^\* SEARCH/i.test(l.line)) for (const x of l.line.replace(/^\* SEARCH/i, "").trim().split(/\s+/)) { const n = Number(x); if (n > after) out.push(n); }
    return [...new Set(out)].sort((a, b) => a - b);
  }
  /** the message (headers and body, its first 200 KB — a bank message is a few hundred bytes) as latin-1, not marked read */
  async fetch(uid: number): Promise<string | null> {
    const r = await this.ok(`UID FETCH ${uid} (BODY.PEEK[]<0.200000>)`, "FETCH");
    for (const l of r.lines) if (/FETCH/i.test(l.line) && l.literals.length) return l.literals[0];
    return null;
  }
  async logout() { try { await this.command("LOGOUT"); } catch { /* the server may just close */ } this.wire.close(); }
}
