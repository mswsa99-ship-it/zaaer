/**
 * Plan 3.2 — the single token file carries the approved values verbatim (tokens.json v1 of the approved RoomAI
 * system). These assertions pin the load-bearing values so a typo or a silent edit fails loudly. Descriptive
 * names, no test codes: prefix registration is left to the integrator.
 */
import { describe, it, expect } from "vitest";
import { colors, textStyles, spacing, radii, shadows, sizes, fontFamilies, declaredPairs, PRODUCT_NAME, POWERED_BY } from "../../src/lib/designTokens";

describe("the single token file (plan 3.2)", () => {
  it("carries the approved identity colours verbatim, نهار وليل", () => {
    expect(colors.night).toMatchObject({ light: "#10343f", dark: "#cfe6e8" });
    expect(colors.spark).toMatchObject({ light: "#0fa3b1", dark: "#38c6d2" });
    expect(colors.saffron).toMatchObject({ light: "#d9952b", dark: "#e8ae4c" });
    expect(colors.sand).toMatchObject({ light: "#f4ede2", dark: "#2a241b" });
    expect(colors.paper).toMatchObject({ light: "#fffffe", dark: "#435054" });
    expect(Object.keys(colors)).toHaveLength(30);
  });

  it("keeps the alpha of the sheer grounds (the approved tokens.css lost it; tokens.json wins)", () => {
    expect(colors["surface-sunken"].light).toBe("rgba(241,235,225,0.6)");
    expect(colors["sand-sheer"].light).toBe("rgba(244,237,226,0.5)");
  });

  it("carries the type, spacing, radius, shadow and size scales verbatim", () => {
    expect(fontFamilies.display).toContain("Readex Pro");
    expect(fontFamilies.sans).toContain("IBM Plex Sans Arabic");
    expect(fontFamilies.mono).toContain("IBM Plex Mono");
    expect(textStyles["display-l"]).toMatchObject({ fontSize: "40px", lineHeight: "48px" });
    expect(textStyles.caption).toMatchObject({ fontSize: "12px", lineHeight: "16px" });
    expect(Object.values(spacing)).toEqual(["4px", "8px", "12px", "16px", "24px", "32px", "48px"]);
    expect(radii).toMatchObject({ "radius-md": "10px", "radius-lg": "16px", "radius-xl": "28px", "radius-pill": "999px" });
    expect(sizes).toEqual({ "target-min": "44px", "field-height": "40px" });
    expect(shadows["shadow-1"].light).toContain("rgba(16,38,45,0.04)");
  });

  it("the name is one word, R and A and I capital; the guest footer line is fixed", () => {
    expect(PRODUCT_NAME).toBe("RoomAI");
    expect(POWERED_BY).toBe("يعمل بـ RoomAI");
  });

  it("every declared pair references real token values (no orphan strings)", () => {
    const all = new Set(Object.values(colors).flatMap((c) => [c.light, c.dark]));
    for (const p of declaredPairs) {
      const composite = ["#f7f3ed", "#faf6f0"].includes(p.background);
      expect(all.has(p.text), `${p.label}: text`).toBe(true);
      expect(all.has(p.background) || composite, `${p.label}: background`).toBe(true);
    }
  });
});
