/**
 * bridge-config.json — written by the owner's page («واتساب الفروع» ← إنشاء مفتاح الربط), once per key:
 *   { "server": "https://<project>.supabase.co/functions/v1/wa-bridge", "key": "zb_<64 hex>", "branch": "…", "branch_phone": "9665…" }
 * Looked for in the program's folder; if it is not there yet, the newest bridge-config*.json in the user's Downloads
 * folder is copied in (so the receptionist does not have to move it by hand).
 * Optional: "browser_path" (Edge/Chrome to use), "browser_args" (extra "--" switches, e.g. a proxy), "headless" (true
 * hides the WhatsApp window — not recommended).
 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

export const CONFIG_NAME = "bridge-config.json";

export class ConfigError extends Error {}

export function validateConfig(raw) {
  const c = typeof raw === "string" ? JSON.parse(raw) : raw;
  if (!c || typeof c !== "object") throw new ConfigError("الملف ليس بصيغة صحيحة.");
  let url;
  try { url = new URL(String(c.server ?? "")); } catch { throw new ConfigError("عنوان الخادم (server) غير صحيح."); }
  if (url.protocol !== "https:" || !/\/functions\/v1\/wa-bridge\/?$/.test(url.pathname)) throw new ConfigError("عنوان الخادم يجب أن يكون https وينتهي بـ /functions/v1/wa-bridge.");
  if (!/^zb_[0-9a-f]{64}$/.test(String(c.key ?? ""))) throw new ConfigError("مفتاح الربط (key) غير صحيح — نزّل ملف إعداد جديدًا.");
  return {
    server: url.toString().replace(/\/$/, ""), key: c.key, branch: String(c.branch ?? ""), branch_phone: c.branch_phone ? String(c.branch_phone).replace(/\D/g, "") : null,
    browser_path: c.browser_path ? String(c.browser_path) : null, headless: c.headless === true,
    // extra browser switches for an unusual computer (e.g. "--proxy-server=…"); only "--" switches are taken
    browser_args: Array.isArray(c.browser_args) ? c.browser_args.map(String).filter((a) => /^--[a-z0-9-]+(=.*)?$/i.test(a)).slice(0, 20) : [],
  };
}

/** the folder's config, else the newest one from Downloads (copied into the folder); null if none anywhere */
export function findConfig(root, { home = os.homedir(), log = null } = {}) {
  const here = path.join(root, CONFIG_NAME);
  if (fs.existsSync(here)) return { file: here, config: validateConfig(fs.readFileSync(here, "utf8")) };
  const downloads = [path.join(home, "Downloads"), path.join(home, "التنزيلات")].filter((d) => fs.existsSync(d));
  const candidates = [];
  for (const d of downloads) {
    for (const f of fs.readdirSync(d)) {
      if (/^bridge-config( ?\(\d+\))?(-\d+)?\.json$/i.test(f)) candidates.push(path.join(d, f));
    }
  }
  candidates.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  for (const f of candidates) {
    try {
      const config = validateConfig(fs.readFileSync(f, "utf8"));
      fs.copyFileSync(f, here);
      log?.info(`وُجد ملف الإعداد في التنزيلات ونُسخ إلى مجلد البرنامج: ${path.basename(f)}`, `Settings file found in Downloads and copied here: ${path.basename(f)}`);
      return { file: here, config };
    } catch { /* not a valid one: try the next */ }
  }
  return null;
}
