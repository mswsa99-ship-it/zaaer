import { describe, expect, it } from "vitest";
import { HUBS, PAGES, type HubId } from "../../src/lib/nav";

// The centre's tab strip sits under the menu entry named after the centre: no tab may repeat that name, or the screen
// shows two links with the same words that lead to different places (S04 caught it for «خدمة الغرف»).
describe("centre tab labels", () => {
  it("no tab of a centre is named like the centre", () => {
    for (const hub of Object.keys(HUBS) as HubId[]) {
      const tabs = PAGES.filter((p) => p.hub === hub).map((p) => p.tabLabel ?? p.label);
      expect(tabs, hub).not.toContain(HUBS[hub].label);
    }
  });
  it("tab labels inside one centre are distinct", () => {
    for (const hub of Object.keys(HUBS) as HubId[]) {
      const tabs = PAGES.filter((p) => p.hub === hub).map((p) => p.tabLabel ?? p.label);
      expect(new Set(tabs).size, hub).toBe(tabs.length);
    }
  });
});
