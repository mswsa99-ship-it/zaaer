import { describe, expect, it } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(__dirname, "../..");
const read = (file: string) => readFileSync(resolve(root, file), "utf8");

describe("self-hosted Arabic and Latin font delivery", () => {
  it("does not load font services from the HTML entry", () => {
    expect(read("index.html")).not.toMatch(/fonts\.(?:googleapis|gstatic)\.com/);
  });

  it("ships both scripts at every existing weight with swap and valid local WOFF2 files", () => {
    expect(existsSync(resolve(root, "src/fonts.css"))).toBe(true);
    const css = read("src/fonts.css");
    const faces = [...css.matchAll(/@font-face\s*\{([^}]+)\}/g)].map((m) => m[1]);
    expect(faces).toHaveLength(10);
    for (const weight of [300, 400, 500, 600, 700]) {
      for (const script of ["arabic", "latin"]) {
        const filename = `ibm-plex-sans-arabic-${script}-${weight}-normal.woff2`;
        const face = faces.find((f) => f.includes(filename));
        expect(face, filename).toBeDefined();
        expect(face).toContain(`font-weight: ${weight}`);
        expect(face).toMatch(/font-display:\s*swap/);
        expect(face).toContain(`/fonts/${filename}`);
        const data = readFileSync(resolve(root, "public/fonts", filename));
        expect(data.subarray(0, 4).toString()).toBe("wOF2");
        expect(data.readUInt32BE(8)).toBe(data.length);
      }
    }
    expect(css).not.toMatch(/https?:\/\//);
    expect(read("src/index.css")).toMatch(/@import\s+["']\.\/fonts\.css["']/);
  });

  it("keeps system fallbacks available and distributes the font license", () => {
    expect(read("src/index.css")).toMatch(/font-family:[^;]+system-ui[^;]+sans-serif/);
    expect(existsSync(resolve(root, "public/fonts/OFL.txt"))).toBe(true);
    expect(read("public/fonts/OFL.txt")).toContain("SIL OPEN FONT LICENSE");
  });
});
