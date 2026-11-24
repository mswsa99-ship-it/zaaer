/**
 * Plan 3.2 — the style rule that rejects directly written colors. Positive and negative controls on invented
 * fixtures; the run against the real tree is the inventory reported with the work package (the gate cannot go
 * green before the token file of the approved design system, gate 3.1, exists).
 */
import { describe, it, expect } from "vitest";
// @ts-expect-error — a plain ES module of the scripts folder, without type declarations
import { findHardcodedColors, isClean } from "../../scripts/lib/colorScan.mjs";

describe("hardcoded color rule (plan 3.2)", () => {
  it("flags hex colors in styles, inline style attributes and Tailwind arbitrary values", () => {
    const src = [
      `const a = <div style={{ background: "#1f5f74" }} />;`,
      `.x { color: #f5f7fa; }`,
      `const b = <div className="bg-[#173e4d] text-white" />;`,
      `const c = <div className="ring-[#abc]" />;`,
    ].join("\n");
    const found = findHardcodedColors(src, "fixture.tsx");
    expect(found.map((f) => f.match)).toEqual(["#1f5f74", "#f5f7fa", "#173e4d", "#abc"]);
    expect(found.every((f) => f.kind === "hex" && f.file === "fixture.tsx")).toBe(true);
    expect(found[0].line).toBe(1);
  });

  it("flags CSS color functions, including inside arbitrary values", () => {
    const src = [
      `.a { background: rgb(31, 95, 116); }`,
      `.b { color: rgba(0,0,0,0.5); }`,
      `const c = <div className="bg-[hsl(200_30%_40%)]" />;`,
    ].join("\n");
    const found = findHardcodedColors(src);
    expect(found.map((f) => f.kind)).toEqual(["function", "function", "function"]);
    expect(found[0].match).toBe("rgb(31, 95, 116)");
  });

  it("accepts named token classes, token references, ids and URL fragments", () => {
    const clean = [
      `const a = <div className="bg-brand-600 text-ink-800 border-border-control" />;`,
      `const el = document.getElementById("root");`,
      `const href = "https://example.com/page#abc123";`,   // a URL fragment of hex letters is not a color
      `background: var(--color-brand-600);`,
      `const id = "#" + code;`,   // a lone «#» is not a color
    ].join("\n");
    expect(isClean(clean)).toBe(true);
  });

  it("exempts only the line carrying the documented marker", () => {
    const src = [
      `const boot = "#14333f"; // token-ok: شاشة الإقلاع قبل تحميل الرموز`,
      `const other = "#14333f";`,
    ].join("\n");
    const found = findHardcodedColors(src);
    expect(found).toHaveLength(1);
    expect(found[0].line).toBe(2);
  });

  it("reports the line and column so a violation points at its place", () => {
    const found = findHardcodedColors("x\n  color: #fff;\n", "f.css");
    expect(found[0]).toMatchObject({ file: "f.css", line: 2, column: 10, match: "#fff" });
  });
});
