import { describe, it, expect } from "vitest";
import { shortcutAction } from "../../src/lib/shortcuts";

describe("keyboard shortcuts decide (6.15)", () => {
  it("Ctrl+S saves, also while typing", () => {
    expect(shortcutAction({ key: "s", ctrlKey: true }, true, false)).toEqual({ type: "save" });
    expect(shortcutAction({ key: "S", metaKey: true }, false, false)).toEqual({ type: "save" });
  });
  it("«/» searches and «?» opens the list, but never while typing", () => {
    expect(shortcutAction({ key: "/" }, false, false)).toEqual({ type: "search" });
    expect(shortcutAction({ key: "?" }, false, false)).toEqual({ type: "go", path: "/staff/shortcuts" });
    expect(shortcutAction({ key: "/" }, true, false)).toBeNull();
    expect(shortcutAction({ key: "g" }, true, false)).toBeNull();
  });
  it("G then T/R/N goes to arrivals, reservations, new reservation; T alone does nothing", () => {
    expect(shortcutAction({ key: "g" }, false, false)).toEqual({ type: "pending-g" });
    expect(shortcutAction({ key: "t" }, false, true)).toEqual({ type: "go", path: "/staff/arrivals" });
    expect(shortcutAction({ key: "r" }, false, true)).toEqual({ type: "go", path: "/staff/reservations" });
    expect(shortcutAction({ key: "n" }, false, true)).toEqual({ type: "go", path: "/staff/reservations/new" });
    expect(shortcutAction({ key: "t" }, false, false)).toBeNull();
  });
  it("other modifier combinations are left to the browser", () => {
    expect(shortcutAction({ key: "g", altKey: true }, false, false)).toBeNull();
    expect(shortcutAction({ key: "/", ctrlKey: true }, false, false)).toBeNull();
  });
});
