/**
 * Log to the window and to logs/bridge-YYYY-MM-DD.log (kept 14 days; open it with Notepad). Numbers are masked
 * (••••1234) and message text is never logged — the conversations themselves live in the system's inbox.
 *
 * Every line has Arabic and English: the file keeps both, the console window shows the English (the Windows console
 * cannot join Arabic letters or run right-to-left).
 */
import fs from "node:fs";
import path from "node:path";
import { mask } from "./core.mjs";

export function createLogger(dir, { keepDays = 14, now = () => new Date(), out = console } = {}) {
  try { fs.mkdirSync(dir, { recursive: true }); } catch { /* console only */ }
  prune(dir, keepDays, now());
  const write = (level, ar, en) => {
    const d = now();
    const stamp = localStamp(d);                                     // the computer's own time (Riyadh), not UTC
    const arText = mask(ar instanceof Error ? ar.message : String(ar ?? ""));
    const enText = en ? mask(String(en)) : null;
    const console_ = `${stamp.slice(11)} ${level === "INFO" ? "" : level + " "}${enText ?? arText}`;
    (level === "ERROR" ? out.error : level === "WARN" ? out.warn : out.log)(console_);
    try { fs.appendFileSync(path.join(dir, `bridge-${stamp.slice(0, 10)}.log`), `${stamp} ${level} ${arText}${enText ? ` | ${enText}` : ""}\n`, "utf8"); } catch { /* disk full / locked */ }
  };
  return { info: (ar, en) => write("INFO", ar, en), warn: (ar, en) => write("WARN", ar, en), error: (ar, en) => write("ERROR", ar, en) };
}

/** "2026-10-24 13:05:09" in the computer's time zone */
export function localStamp(d) {
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function prune(dir, keepDays, today) {
  try {
    const limit = today.getTime() - keepDays * 86_400_000;
    for (const f of fs.readdirSync(dir)) {
      const m = /^bridge-(\d{4}-\d{2}-\d{2})\.log$/.exec(f);
      if (m && Date.parse(m[1]) < limit) fs.rmSync(path.join(dir, f), { force: true });
    }
  } catch { /* ignore */ }
}
