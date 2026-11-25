/**
 * Plan phase 3, item 3.6 — tests for scripts/check-app-assets.mjs with positive and negative fixtures.
 * The script is the plan's «فحص ملف التطبيق»: it must pass on a complete asset set and name what is
 * missing or mismatched on a broken one. Runs on invented fixture files only, never on a live site.
 */
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { checkAssets, pngSize } from "../../scripts/check-app-assets.mjs";

/** A minimal PNG byte stream whose IHDR declares the given size (enough for the checker, not for viewing). */
function fakePng(width, height) {
  const b = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(b, 0); // signature
  b.writeUInt32BE(13, 8); // IHDR length
  Buffer.from("IHDR").copy(b, 12);
  b.writeUInt32BE(width, 16);
  b.writeUInt32BE(height, 20);
  b[24] = 8; b[25] = 2; // bit depth, truecolor
  return b;
}

const MANIFEST = {
  name: "RoomAI — فندق الاختبار",
  short_name: "RoomAI",
  display: "standalone",
  theme_color: "#14333f",
  icons: [
    { src: "/icon-192.png", sizes: "192x192", type: "image/png" },
    { src: "/icon-512.png", sizes: "512x512", type: "image/png" },
    { src: "/icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
  ],
};

const HTML_DOC = `<!doctype html><html><head>
<link rel="manifest" href="/manifest.webmanifest" />
<link rel="apple-touch-icon" href="/icon-192.png" />
<meta property="og:image" content="/og-image.png" />
<meta name="theme-color" content="#14333f" />
</head><body></body></html>`;

let dir;
beforeAll(() => { dir = mkdtempSync(join(tmpdir(), "app-assets-")); });
afterAll(() => { rmSync(dir, { recursive: true, force: true }); });

function fixture(name, fill) {
  const root = join(dir, name, "public");
  mkdirSync(root, { recursive: true });
  const html = join(dir, name, "index.html");
  writeFileSync(html, HTML_DOC);
  fill(root, html);
  return { root, html };
}

function complete(root) {
  writeFileSync(join(root, "logo.svg"), "<svg xmlns=\"http://www.w3.org/2000/svg\"/>");
  for (const size of [32, 192, 512]) writeFileSync(join(root, `icon-${size}.png`), fakePng(size, size));
  writeFileSync(join(root, "icon-maskable-512.png"), fakePng(512, 512));
  writeFileSync(join(root, "og-image.png"), fakePng(1200, 630));
  writeFileSync(join(root, "manifest.webmanifest"), JSON.stringify(MANIFEST));
}

describe("app-assets check (plan item 3.6)", () => {
  it("pngSize reads real PNG dimensions and rejects non-PNG bytes", () => {
    const root = join(dir, "dims");
    mkdirSync(root, { recursive: true });
    const f = join(root, "a.png");
    writeFileSync(f, fakePng(192, 192));
    expect(pngSize(f)).toEqual({ width: 192, height: 192 });
    writeFileSync(f, "not a png");
    expect(pngSize(f)).toBeNull();
    expect(pngSize(join(root, "missing.png"))).toBeNull();
  });

  it("a complete asset set passes with nothing missing", () => {
    const { root, html } = fixture("complete", complete);
    const r = checkAssets({ root, html });
    expect(r.problems).toEqual([]);
    expect(r.passed).toBe(true);
  });

  it("an empty public directory fails and names every required piece", () => {
    const { root, html } = fixture("empty", () => {});
    const r = checkAssets({ root, html });
    expect(r.passed).toBe(false);
    expect(r.problems.join("\n")).toMatch(/SVG/);
    expect(r.problems.join("\n")).toMatch(/32×32/);
    expect(r.problems.join("\n")).toMatch(/192×192/);
    expect(r.problems.join("\n")).toMatch(/512×512/);
    expect(r.problems.join("\n")).toMatch(/ملف التطبيق/);
    expect(r.problems.join("\n")).toMatch(/صورة المشاركة/);
  });

  it("an icon whose real size differs from its name is rejected", () => {
    const { root, html } = fixture("wrong-size", (pub) => {
      complete(pub);
      writeFileSync(join(pub, "icon-512.png"), fakePng(256, 256)); // named 512, actually 256
    });
    const r = checkAssets({ root, html });
    expect(r.passed).toBe(false);
    expect(r.problems.join("\n")).toMatch(/icon-512\.png مقاسها الفعلي 256×256/);
  });

  it("a manifest without a maskable icon is rejected", () => {
    const { root, html } = fixture("no-maskable", (pub) => {
      complete(pub);
      const m = { ...MANIFEST, icons: MANIFEST.icons.filter((i) => i.purpose !== "maskable") };
      writeFileSync(join(pub, "manifest.webmanifest"), JSON.stringify(m));
    });
    const r = checkAssets({ root, html });
    expect(r.passed).toBe(false);
    expect(r.problems.join("\n")).toMatch(/maskable/);
  });

  it("a manifest icon entry pointing at a missing file is rejected", () => {
    const { root, html } = fixture("dangling", (pub) => {
      complete(pub);
      rmSync(join(pub, "icon-192.png"));
    });
    const r = checkAssets({ root, html });
    expect(r.passed).toBe(false);
    expect(r.problems.join("\n")).toMatch(/192×192/);
  });

  it("index.html without manifest and share-picture wiring is rejected", () => {
    const { root, html } = fixture("bare-html", (pub, doc) => {
      complete(pub);
      writeFileSync(doc, "<!doctype html><html><head></head><body></body></html>");
    });
    const r = checkAssets({ root, html });
    expect(r.passed).toBe(false);
    expect(r.problems.join("\n")).toMatch(/rel="manifest"/);
    expect(r.problems.join("\n")).toMatch(/apple-touch-icon/);
    expect(r.problems.join("\n")).toMatch(/og:image/);
  });
});
