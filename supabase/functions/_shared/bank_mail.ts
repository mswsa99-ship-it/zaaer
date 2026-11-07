/**
 * One reading of the bank mailbox (A6): the settings from the database (fn_bank_mail_poll_config, service role), the
 * messages after the last one read, each handed whole to fn_bank_ingest (which keeps the raw text first and decides),
 * and where it stopped (fn_bank_mail_poll_done). A message is passed only once it is stored; an error stops the reading
 * there, and the next reading starts again from the first message not stored.
 */
import { Imap, type Wire } from "./imap.ts";
import { readMail } from "./mime.ts";

// deno-lint-ignore no-explicit-any
type Db = { rpc: (fn: string, args?: Record<string, unknown>) => PromiseLike<{ data: any; error: { message: string } | null }> };
export interface PollResult { configured: boolean; fetched: number; results: Array<{ uid: number; status: string; reason?: string }>; error?: string }

export async function pollMailbox(db: Db, connect: (host: string, port: number) => Promise<Wire>, max = 25): Promise<PollResult> {
  const cfg = await db.rpc("fn_bank_mail_poll_config");
  if (cfg.error) throw new Error("CONFIG: " + cfg.error.message);
  const c = cfg.data as { configured: boolean; host: string; port: number; user: string; password: string; last_uid: number; uid_validity: number | null };
  if (!c?.configured) return { configured: false, fetched: 0, results: [] };
  const out: PollResult = { configured: true, fetched: 0, results: [] };
  let last = Number(c.last_uid) || 0; let validity: number | null = null; let err: string | null = null;
  let imap: Imap | null = null;
  try {
    imap = new Imap(await connect(c.host, c.port));
    await imap.greeting();
    await imap.login(c.user, c.password);
    validity = await imap.examineInbox();
    if (validity !== null && c.uid_validity !== null && validity !== Number(c.uid_validity)) last = 0;   // the mailbox was renumbered
    for (const uid of (await imap.uidsAfter(last)).slice(0, max)) {
      const raw = await imap.fetch(uid);
      if (raw === null) { out.results.push({ uid, status: "empty" }); last = uid; continue; }
      let r: { data: { duplicate?: boolean; status?: string; reason?: string } | null; error: { message: string } | null };
      try { r = await db.rpc("fn_bank_ingest", { p: readMail(raw) }); } catch (e) { r = { data: null, error: { message: String((e as Error)?.message ?? e) } }; }
      if (r.error) {
        // one email that cannot be stored must not stop every later reading: a placeholder is kept and the reading moves on
        const f = await db.rpc("fn_bank_ingest_failed", { p_uid: uid, p_error: r.error.message.slice(0, 150) });
        if (f.error) throw new Error("INGEST: " + r.error.message);
        out.results.push({ uid, status: "failed", reason: r.error.message.slice(0, 150) }); last = uid; continue;
      }
      out.results.push({ uid, status: r.data?.duplicate ? "duplicate" : r.data?.status ?? "kept", reason: r.data?.reason });
      out.fetched++; last = uid;
    }
  } catch (e) {
    // the password never goes into the error kept for the owner or returned (masked before it is cut)
    err = String((e as Error)?.message ?? e);
    if (c.password) err = err.split(c.password).join("•••");
    err = err.slice(0, 300);
    out.error = err;
  } finally {
    if (imap) await imap.logout();
  }
  await db.rpc("fn_bank_mail_poll_done", { p_last_uid: last, p_uid_validity: validity, p_error: err });
  return out;
}
