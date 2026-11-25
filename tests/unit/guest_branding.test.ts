import { describe, expect, it } from "vitest";
import { guestLogoSource } from "../../src/lib/guestBranding";

describe("guest hotel logo boundary", () => {
  it("accepts uploaded raster logos and HTTPS images", () => {
    expect(guestLogoSource("data:image/png;base64,aGVsbG8=")).toBe("data:image/png;base64,aGVsbG8=");
    expect(guestLogoSource("https://images.example.test/hotel.png")).toBe("https://images.example.test/hotel.png");
  });
  it("rejects script, SVG, insecure and malformed logo values", () => {
    for (const logo of [null, "javascript:alert(1)", "data:image/svg+xml;base64,PHN2Zz4=", "http://images.example.test/a.png", "https://user:pass@example.test/a", "not a url"]) {
      expect(guestLogoSource(logo)).toBeNull();
    }
  });
});
