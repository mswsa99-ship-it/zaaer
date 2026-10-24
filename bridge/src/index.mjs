/**
 * زائر — ربط واتساب الفرع بكمبيوتر الاستقبال (WhatsApp Web)
 *
 * Opens WhatsApp Web in the computer's own Chrome/Edge (a visible window: scan the QR once from the branch phone,
 * then it stays linked), reads every new guest message, and types the system's answer like an employee would.
 * Started by start.bat (which restarts it if it ever stops). See README-AR.txt.
 */
import fs from "node:fs";
import net from "node:net";
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { Bridge } from "./core.mjs";
import { findConfig, ConfigError, CONFIG_NAME } from "./config.mjs";
import { findBrowser } from "./browser.mjs";
import { createApi } from "./api.mjs";
import { createLogger } from "./log.mjs";
import { waAdapter, toMsg } from "./wa.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(import.meta.url);
const VERSION = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8")).version;
const log = createLogger(path.join(ROOT, "logs"));
const EXIT_STOP = 0, EXIT_RESTART = 1, EXIT_CONFIG = 2;

log.info(`برنامج ربط واتساب الفرع — الإصدار ${VERSION}`, `Branch WhatsApp link — version ${VERSION}`);

// ---- settings file (from the owner's page) ----
let config;
try {
  const found = findConfig(ROOT, { log });
  if (!found) {
    log.error(`لا يوجد ملف ${CONFIG_NAME}. أنشئه من النظام: «واتساب الفروع» ← إنشاء مفتاح الربط، ثم ضعه في هذا المجلد: ${ROOT}`, `${CONFIG_NAME} not found. Create it in the system (Branch WhatsApp → create the link key) and put it in: ${ROOT}`);
    process.exit(EXIT_CONFIG);
  }
  config = found.config;
  log.info(`الفرع: ${config.branch || "—"}${config.branch_phone ? ` · رقم الفرع ••••${config.branch_phone.slice(-4)}` : ""}`, `Branch number ••••${(config.branch_phone ?? "").slice(-4) || "—"}`);
} catch (e) {
  log.error(`ملف ${CONFIG_NAME} غير صالح: ${e instanceof ConfigError ? e.message : e}`, `${CONFIG_NAME} is not valid — download a new one from the system.`);
  process.exit(EXIT_CONFIG);
}

// ---- one copy per folder (two would fight over the same WhatsApp session) ----
// A local port held while the program runs: the system frees it the moment the program ends, however it ends
// (no lock file left behind by a crash). Each folder has its own port, so two branches can share a computer.
const LOCK_PORT = 41000 + (parseInt(crypto.createHash("sha256").update(ROOT.toLowerCase()).digest("hex").slice(0, 8), 16) % 8000);
const lock = net.createServer((s) => s.destroy());
await new Promise((resolve) => {
  lock.once("error", (e) => {
    if (e?.code === "EADDRINUSE") { log.error("البرنامج يعمل بالفعل في نافذة أخرى. أغلق هذه النافذة.", "The program is already running in another window. Close this one."); process.exit(EXIT_CONFIG); }
    log.warn(`تعذّر التحقق من تشغيل نسخة أخرى (${e?.code ?? e}) — يستمر البرنامج.`, `Could not check for another running copy (${e?.code ?? e}) — continuing.`);
    resolve();
  });
  lock.listen(LOCK_PORT, "127.0.0.1", resolve);
});

const browser = findBrowser(config.browser_path);
if (!browser) {
  log.error("لم يُعثر على متصفح Google Chrome أو Microsoft Edge على هذا الكمبيوتر. ثبّت أحدهما ثم أعد التشغيل.", "Google Chrome or Microsoft Edge was not found on this computer. Install one and start again.");
  process.exit(EXIT_CONFIG);
}
log.info(`المتصفح: ${path.basename(browser)}`, `Browser: ${path.basename(browser)}`);

const core = new Bridge({ api: createApi(config), log, version: VERSION, branchPhone: config.branch_phone });
core.onTrouble = (why) => { core.setStatus("disconnected", why); restart(5_000); };
core.runPollLoop();

// ---- WhatsApp Web ----
const { Client, LocalAuth } = require("whatsapp-web.js");
let client = null; let restarting = false; let stopping = false;

async function start() {
  core.setStatus("starting");
  client = new Client({
    authStrategy: new LocalAuth({ dataPath: path.join(ROOT, "session"), clientId: "branch" }),
    puppeteer: {
      headless: config.headless, executablePath: browser, defaultViewport: null,
      args: ["--no-first-run", "--no-default-browser-check", "--window-size=1100,850", "--disable-features=Translate", ...config.browser_args],
    },
  });
  const c = client;
  core.attach(waAdapter(c));
  c.on("qr", () => {
    core.setStatus("qr");
    log.info("امسح رمز QR الظاهر في نافذة واتساب من جوال الفرع: واتساب ← الإعدادات ← الأجهزة المرتبطة ← ربط جهاز.", "Scan the QR code in the WhatsApp window with the branch phone: WhatsApp → Settings → Linked devices → Link a device.");
  });
  c.on("authenticated", () => log.info("تم التحقق من الجوال.", "Phone verified."));
  c.on("auth_failure", (m) => { core.setStatus("disconnected", "auth_failure"); log.error(`فشل الربط: ${m}`, `Link failed: ${m}`); restart(30_000); });
  c.on("ready", async () => {
    const phone = c.info?.wid?.user ?? null;
    const link = core.setMe({ phone, name: c.info?.pushname ?? null });   // another phone than the branch's: nothing is worked
    core.setStatus("connected");
    if (link === "blocked") return;
    log.info("واتساب جاهز — الرد على الرسائل الجديدة يعمل. اترك هذه النافذة ونافذة واتساب مفتوحتين (يمكن تصغيرهما).", "WhatsApp is ready — new messages are answered. Keep this window and the WhatsApp window open (minimised is fine).");
    await core.catchUp();
  });
  c.on("message", (m) => { core.onIncoming(toMsg(m)); });
  c.on("message_create", (m) => { if (m.fromMe) core.onOwnMessage(toMsg(m)); });
  c.on("disconnected", (reason) => {
    core.setStatus("disconnected", String(reason ?? ""));
    log.warn(reason === "LOGOUT" ? "أُلغي ربط هذا الكمبيوتر من الجوال. سيظهر رمز QR جديد للمسح." : `انقطع واتساب (${reason}). إعادة المحاولة…`,
      reason === "LOGOUT" ? "This computer was unlinked from the phone. A new QR code will appear." : `WhatsApp disconnected (${reason}). Retrying…`);
    restart(10_000);
  });
  try {
    await c.initialize();
    c.pupBrowser?.on("disconnected", () => { if (!stopping && client === c) { log.warn("أُغلقت نافذة واتساب — تُفتح من جديد.", "The WhatsApp window was closed — opening it again."); restart(5_000); } });
  } catch (e) {
    log.error(`تعذّر فتح واتساب ويب: ${e?.message ?? e}`, `Could not open WhatsApp Web: ${e?.message ?? e}`);
    restart(30_000);
  }
}

function restart(delay) {
  if (restarting || stopping) return;
  restarting = true;
  const old = client; client = null;
  Promise.resolve(old?.destroy()).catch(() => {}).finally(() => {
    setTimeout(() => { restarting = false; if (!stopping) start(); }, delay);
  });
}

// ---- health check: WhatsApp Web can stop working without saying so (the tab crashed, a reload the library did not
// follow). Every minute its own state is asked; two failed checks in a row → it is reopened. ----
let healthFails = 0;
setInterval(async () => {
  const c = client;
  if (stopping || restarting || !c || core.status !== "connected") { healthFails = 0; return; }
  let state = null;
  try { state = await Promise.race([c.getState(), new Promise((_, no) => setTimeout(() => no(new Error("timeout")), 20_000))]); } catch { state = null; }
  if (client !== c) return;
  if (state === "CONNECTED") { healthFails = 0; return; }
  if (++healthFails < 2) return;
  healthFails = 0;
  log.warn(`واتساب ويب لا يستجيب (${state ?? "لا رد"}) — يُعاد فتحه.`, `WhatsApp Web is not responding (${state ?? "no answer"}) — reopening it.`);
  core.setStatus("disconnected", "health_check");
  restart(5_000);
}, 60_000);

async function stop(code = EXIT_STOP) {
  if (stopping) return;
  stopping = true;
  log.info("إيقاف البرنامج…", "Stopping…");
  core.setStatus("stopped");
  try { await core.api.poll({ status: "stopped", version: VERSION, wait: 0 }); } catch { /* best effort */ }
  core.stop();
  try { await client?.destroy(); } catch { /* ignore */ }
  try { lock.close(); } catch { /* freed on exit anyway */ }
  process.exit(code);
}

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP", "SIGBREAK"]) process.on(sig, () => stop(EXIT_STOP));
process.on("uncaughtException", (e) => { log.error(`خطأ غير متوقع: ${e?.stack ?? e}`, `Unexpected error: ${e?.stack ?? e}`); stop(EXIT_RESTART); });
process.on("unhandledRejection", (e) => { log.error(`خطأ غير متوقع: ${e?.stack ?? e}`, `Unexpected error: ${e?.stack ?? e}`); });

start();
