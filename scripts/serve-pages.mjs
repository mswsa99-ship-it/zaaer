#!/usr/bin/env node
/**
 * Serves a built site the way GitHub Pages serves a project site, so a build can be checked against the real
 * backend BEFORE it is published (staging.yml) — and so the sub-path + 404.html fallback can be tried locally:
 *   - files are under <base>/ (e.g. /zaaer/assets/…); <base> without the slash redirects to <base>/
 *   - an unknown path gets <dir>/404.html with status 404 (Pages has no rewrites; the SPA is that page)
 *
 *   node scripts/serve-pages.mjs dist /zaaer 4390
 */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const [dirArg = "dist", baseArg = "", portArg = "4390"] = process.argv.slice(2);
const root = path.resolve(dirArg);
const base = ("/" + baseArg.replace(/^\/+|\/+$/g, "")).replace(/^\/$/, "");
const port = Number(portArg);
const TYPES = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml", ".json": "application/json", ".png": "image/png", ".ico": "image/x-icon",
  ".woff2": "font/woff2", ".webmanifest": "application/manifest+json", ".txt": "text/plain; charset=utf-8",
};

function send(res, status, file) {
  res.writeHead(status, { "content-type": TYPES[path.extname(file)] ?? "application/octet-stream", "cache-control": "no-store" });
  fs.createReadStream(file).pipe(res);
}

http.createServer((req, res) => {
  let pathname;
  try { pathname = decodeURIComponent(new URL(req.url ?? "/", "http://localhost").pathname); } catch { res.writeHead(400); res.end(); return; }
  if (base && pathname === base) { res.writeHead(301, { location: `${base}/` }); res.end(); return; }
  const fallback = path.join(root, "404.html");
  if (base && !pathname.startsWith(`${base}/`)) { if (fs.existsSync(fallback)) send(res, 404, fallback); else { res.writeHead(404); res.end(); } return; }
  const rel = pathname.slice(base.length + 1);
  let file = path.join(root, rel || "index.html");
  if (!file.startsWith(root)) { res.writeHead(403); res.end(); return; }               // no ../ escapes
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, "index.html");
  if (fs.existsSync(file)) send(res, 200, file);
  else if (fs.existsSync(fallback)) send(res, 404, fallback);
  else { res.writeHead(404); res.end(); }
}).listen(port, "127.0.0.1", () => console.log(`serving ${root} at http://localhost:${port}${base}/`));
