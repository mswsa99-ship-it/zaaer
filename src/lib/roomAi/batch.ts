import type { DraftItem, Snapshot } from "./types";

/** Result of one item in a confirmed batch. «failed» and «stopped» stay retryable. */
export interface Outcome { state: "ok" | "skipped" | "failed" | "stopped"; msg?: string }

/** Latest-wins token: a response that belongs to an older operation is dropped (propose, review, reads). */
export function createOpGuard() {
  let n = 0;
  return { next: () => ++n, isCurrent: (t: number) => t === n, bump: () => { n++; } };
}

export interface BatchOptions {
  items: DraftItem[];
  /** the branch the user confirmed for; the batch never writes anywhere else */
  pinnedBranch: string;
  currentBranch: () => string | null;
  /** synchronous re-entry lock (a ref), so a double click cannot start two batches */
  lock: { busy: boolean };
  /** a fresh read of the pinned branch; null when the read failed */
  refresh: () => Promise<Snapshot | null>;
  exists: (d: DraftItem, s: Snapshot) => boolean;
  write: (d: DraftItem, s: Snapshot) => Promise<void>;
  onResult: (id: string, o: Outcome) => void;
}
export type BatchEnd = "done" | "locked" | "no-snapshot" | "branch-changed";

/**
 * Writes the confirmed items one by one. Before the first item and after every item it re-reads the branch, so the
 * next write sees what the previous one really did (a half-finished item is retried, not duplicated). If the active
 * branch is no longer the pinned one, or a read fails, the rest stops and is reported as stopped, never written.
 */
export async function runBatch(o: BatchOptions): Promise<BatchEnd> {
  if (o.lock.busy) return "locked";
  o.lock.busy = true;
  try {
    let s = await o.refresh();
    if (!s) { for (const d of o.items) o.onResult(d.id, { state: "stopped", msg: "تعذّرت قراءة الفرع. لم يُكتب شيء." }); return "no-snapshot"; }
    for (let i = 0; i < o.items.length; i++) {
      const d = o.items[i];
      if (o.currentBranch() !== o.pinnedBranch) { for (const r of o.items.slice(i)) o.onResult(r.id, { state: "stopped", msg: "تغيّر الفرع أثناء التنفيذ فأُوقف. لم يُكتب." }); return "branch-changed"; }
      if (!s) { for (const r of o.items.slice(i)) o.onResult(r.id, { state: "stopped", msg: "تعذّرت قراءة الفرع بعد البند السابق. أعد المحاولة." }); return "no-snapshot"; }
      if (o.exists(d, s)) { o.onResult(d.id, { state: "skipped", msg: "موجود مسبقًا" }); continue; }
      try { await o.write(d, s); o.onResult(d.id, { state: "ok" }); }
      catch (e) { o.onResult(d.id, { state: "failed", msg: (e as Error).message }); }
      s = await o.refresh();
    }
    return "done";
  } finally { o.lock.busy = false; }
}
