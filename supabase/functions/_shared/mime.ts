/**
 * Reading one email (RFC 5322 / MIME) as the bank-mail function needs it: who sent it, its Message-ID, date and subject,
 * and its text (the first text/plain part, its transfer encoding and charset undone). Pure code: no Deno, no network,
 * so the unit tests run it as it is.
 */
export interface MailText { from: string; message_id: string; date: string; subject: string; body: string }

const dec = (bytes: Uint8Array, charset: string) => {
  try { return new TextDecoder(charset || "utf-8").decode(bytes); } catch { return new TextDecoder("utf-8").decode(bytes); }
};
const latin1 = (s: string) => { const b = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff; return b; };

export function fromBase64(s: string): Uint8Array {
  const clean = s.replace(/[^A-Za-z0-9+/=]/g, "");
  return latin1(atob(clean));
}
export function fromQuotedPrintable(s: string): Uint8Array {
  const soft = s.replace(/=\r?\n/g, "");
  const out: number[] = [];
  for (let i = 0; i < soft.length; i++) {
    const c = soft[i];
    if (c === "=" && /^[0-9A-Fa-f]{2}$/.test(soft.slice(i + 1, i + 3))) { out.push(parseInt(soft.slice(i + 1, i + 3), 16)); i += 2; }
    else out.push(soft.charCodeAt(i) & 0xff);
  }
  return new Uint8Array(out);
}

/** =?UTF-8?B?...?= and =?UTF-8?Q?...?= in a header */
export function decodeWords(v: string): string {
  return v.replace(/=\?([^?]+)\?([BbQq])\?([^?]*)\?=(\s+(?==\?))?/g, (_m, cs: string, enc: string, txt: string) =>
    dec(enc.toUpperCase() === "B" ? fromBase64(txt) : fromQuotedPrintable(txt.replace(/_/g, " ")), cs.toLowerCase()));
}

/** headers (unfolded, names lower-cased; the first of each kept) and the raw body */
export function splitMessage(raw: string): { headers: Record<string, string>; body: string } {
  const text = raw.replace(/\r\n/g, "\n");
  const cut = text.indexOf("\n\n");
  const head = cut < 0 ? text : text.slice(0, cut);
  const body = cut < 0 ? "" : text.slice(cut + 2);
  const headers: Record<string, string> = {};
  for (const line of head.replace(/\n[ \t]+/g, " ").split("\n")) {
    const i = line.indexOf(":");
    if (i <= 0) continue;
    const k = line.slice(0, i).trim().toLowerCase();
    if (!(k in headers)) headers[k] = line.slice(i + 1).trim();
  }
  return { headers, body };
}

const param = (v: string, name: string) => {
  const m = new RegExp(`${name}\\s*=\\s*(?:"([^"]*)"|([^;\\s]+))`, "i").exec(v);
  return m ? (m[1] ?? m[2]) : "";
};

/** the first text/plain part of a (possibly multipart) body, decoded */
export function plainText(headers: Record<string, string>, body: string, depth = 0): string | null {
  const type = (headers["content-type"] ?? "text/plain").toLowerCase();
  if (type.startsWith("multipart/") && depth < 5) {
    const boundary = param(headers["content-type"], "boundary");
    if (!boundary) return null;
    const parts = body.split(new RegExp(`\\n?--${boundary.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?:--)?[ \\t]*\\n?`));
    for (const p of parts) {
      if (!p.trim()) continue;
      const sub = splitMessage(p);
      const t = plainText(sub.headers, sub.body, depth + 1);
      if (t !== null) return t;
    }
    return null;
  }
  if (!type.startsWith("text/plain") && headers["content-type"]) return null;
  const enc = (headers["content-transfer-encoding"] ?? "7bit").toLowerCase();
  const charset = param(headers["content-type"] ?? "", "charset").toLowerCase() || "utf-8";
  if (enc === "base64") return dec(fromBase64(body), charset);
  if (enc === "quoted-printable") return dec(fromQuotedPrintable(body), charset);
  return dec(latin1(body), charset);
}

/** raw: the message as the server sent it (bytes read as latin-1, one char per byte, so charsets decode exactly) */
export function readMail(raw: string): MailText {
  const m = readMailRaw(raw);
  // a NUL cannot be stored (Postgres text), and none belongs in a bank message
  const clean = (s: string) => s.replace(/\x00/g, "");
  return { from: clean(m.from), message_id: clean(m.message_id), date: m.date, subject: clean(m.subject), body: clean(m.body) };
}

function readMailRaw(raw: string): MailText {
  const { headers, body } = splitMessage(raw);
  const text = plainText(headers, body) ?? "";
  return {
    from: decodeWords(headers["from"] ?? ""),
    message_id: (headers["message-id"] ?? "").trim(),
    date: (() => { const d = new Date(headers["date"] ?? ""); return isNaN(d.getTime()) ? "" : d.toISOString(); })(),
    subject: decodeWords(headers["subject"] ?? ""),
    body: text.replace(/\r\n/g, "\n").replace(/\n+$/, ""),
  };
}
