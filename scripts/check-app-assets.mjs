#!/usr/bin/env node
/**
 * Plan phase 3, item 3.6 — «الشعار وملفات التطبيق».
 * Checks that the app-identity files the plan requires actually exist and agree with each other:
 *
 *   - an SVG logo (the master RoomAI mark),
 *   - PNG icons at 32, 192 and 512 px (real pixel sizes read from the files, not the names),
 *   - a maskable icon (declared `purpose: "maskable"` in the web app manifest),
 *   - a share (og:image) picture,
 *   - a web app manifest naming the app and listing the icons,
 *   - index.html pointing at the manifest, the touch icon and the share picture.
 *
 * Usage: node scripts/check-app-assets.mjs [--root DIR] [--html FILE] [--json]
 * Exit 0 when every required file is present and consistent, 1 with the missing/broken list otherwise.
 * No network, no dependencies — reads files only.
 */
import { readFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";

const args = process.argv.slice(2);
function opt(name, fallback) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
}
const ROOT = resolve(opt("root", "public"));
const HTML = resolve(opt("html", "index.html"));
const asJson = args.includes("--json");

/** Icon sizes (px) the plan requires as real PNG files. */
const REQUIRED_PNG = [32, 192, 512];
const SHARE_MIN = { width: 1200, height: 630 };

/** Read a PNG's real dimensions from its IHDR header; null when the file is not a PNG. */
export function pngSize(file) {
  let b;
  try { b = readFileSync(file); } catch { return null; }
  if (b.length < 24 || b[0] !== 0x89 || b.toString("ascii", 1, 4) !== "PNG" || b.toString("ascii", 12, 16) !== "IHDR") return null;
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
}

function hasSvgLogo(root) {
  for (const name of ["brand/roomai-logo.svg", "logo.svg", "roomai.svg", "brand.svg"]) if (existsSync(join(root, name))) return name;
  return null;
}

export function checkAssets({ root = ROOT, html = HTML } = {}) {
  const problems = [];
  const ok = [];

  // 1) the SVG master logo
  const svg = hasSvgLogo(root);
  if (svg) ok.push(`الشعار الأم SVG موجود (${svg})`);
  else problems.push("الشعار الأم SVG غير موجود (public/brand/roomai-logo.svg) — ينتظر ملف الشعار المعتمد");

  // 2) PNG icons with their real sizes
  for (const size of REQUIRED_PNG) {
    const file = join(root, `icon-${size}.png`);
    const dim = existsSync(file) ? pngSize(file) : null;
    if (!existsSync(file)) problems.push(`أيقونة ${size}×${size} غير موجودة (public/icon-${size}.png)`);
    else if (!dim) problems.push(`public/icon-${size}.png ليست PNG صالحة`);
    else if (dim.width !== size || dim.height !== size) problems.push(`public/icon-${size}.png مقاسها الفعلي ${dim.width}×${dim.height} وليس ${size}×${size}`);
    else ok.push(`أيقونة ${size}×${size} سليمة`);
  }

  // 3) the web app manifest
  const manifestPath = ["manifest.webmanifest", "site.webmanifest", "manifest.json"].map((n) => join(root, n)).find(existsSync);
  let manifest = null;
  if (!manifestPath) problems.push("ملف التطبيق (web app manifest) غير موجود في public");
  else {
    try { manifest = JSON.parse(readFileSync(manifestPath, "utf8")); }
    catch { problems.push(`ملف التطبيق ${manifestPath} ليس JSON صالحًا`); }
  }
  if (manifest) {
    if (!manifest.name && !manifest.short_name) problems.push("ملف التطبيق بلا اسم (name/short_name)");
    else ok.push(`اسم التطبيق في الملف: ${manifest.name ?? manifest.short_name}`);
    const icons = Array.isArray(manifest.icons) ? manifest.icons : [];
    for (const size of REQUIRED_PNG) {
      if (size === 32) continue; // the 32px icon is the browser tab's; the manifest needs 192/512
      const entry = icons.find((i) => String(i.sizes ?? "").split(/\s+/).includes(`${size}x${size}`));
      if (!entry) problems.push(`ملف التطبيق لا يسرد أيقونة ${size}×${size}`);
      else {
        const dim = pngSize(join(root, String(entry.src).replace(/^\//, "")));
        if (!dim || dim.width !== size || dim.height !== size) problems.push(`أيقونة ${size}×${size} المذكورة في ملف التطبيق (${entry.src}) غير موجودة أو مقاسها لا يطابق`);
      }
    }
    if (!icons.some((i) => String(i.purpose ?? "").includes("maskable"))) problems.push("لا أيقونة قابلة للقص (maskable) في ملف التطبيق");
    else ok.push("الأيقونة القابلة للقص (maskable) مسجلة");
    if (!manifest.display) problems.push("ملف التطبيق بلا display (standalone مطلوب لشاشة البداية)");
    if (!manifest.theme_color) problems.push("ملف التطبيق بلا theme_color");
  }

  // 4) the share picture
  const shareCandidates = ["og-image.png", "share.png", "og-image.jpg", "share.jpg"];
  const share = shareCandidates.find((n) => existsSync(join(root, n)));
  if (!share) problems.push(`صورة المشاركة غير موجودة (مثل public/og-image.png، ${SHARE_MIN.width}×${SHARE_MIN.height} أو أكبر)`);
  else if (share.endsWith(".png")) {
    const dim = pngSize(join(root, share));
    if (!dim || dim.width < SHARE_MIN.width || dim.height < SHARE_MIN.height) problems.push(`صورة المشاركة ${share} مقاسها ${dim ? `${dim.width}×${dim.height}` : "غير مقروء"} والمطلوب ${SHARE_MIN.width}×${SHARE_MIN.height} على الأقل`);
    else ok.push(`صورة المشاركة سليمة (${dim.width}×${dim.height})`);
  } else ok.push(`صورة المشاركة موجودة (${share})`);

  // 5) index.html wiring
  let doc = "";
  try { doc = readFileSync(html, "utf8"); } catch { problems.push(`index.html غير مقروء (${html})`); }
  if (doc) {
    if (!/rel=["']manifest["']/.test(doc)) problems.push("index.html لا يشير إلى ملف التطبيق (<link rel=\"manifest\">)");
    else ok.push("index.html يشير إلى ملف التطبيق");
    if (!/rel=["']apple-touch-icon["']/.test(doc)) problems.push("index.html بلا apple-touch-icon");
    if (!/property=["']og:image["']/.test(doc)) problems.push("index.html بلا og:image لصورة المشاركة");
    if (!/name=["']theme-color["']/.test(doc)) problems.push("index.html بلا theme-color");
  }

  return { ok, problems, passed: problems.length === 0 };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname);
if (isMain) {
  const result = checkAssets();
  if (asJson) console.log(JSON.stringify(result, null, 2));
  else {
    console.log("فحص ملفات التطبيق والشعار (البند 3.6):");
    for (const line of result.ok) console.log(`  نعم — ${line}`);
    for (const line of result.problems) console.log(`  ناقص — ${line}`);
    console.log(result.passed ? "كل ملفات البند 3.6 حاضرة." : `ينقص ${result.problems.length} من متطلبات البند 3.6.`);
  }
  process.exit(result.passed ? 0 : 1);
}
