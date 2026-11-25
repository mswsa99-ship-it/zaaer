import { describe, expect, it } from "vitest";
import { inboxAffordances } from "../../src/lib/inboxAffordances";
import { EMPTY_INDIVIDUAL, type IndividualPermissions } from "../../src/lib/individualPermissions";

const ind = (inbox: Record<string, boolean>): IndividualPermissions => ({ mode: "individual", revision: 1, pages: { "/staff/inbox": inbox }, sensitive: [], homePage: null });

describe("inbox affordances (0128: reply is add, take is edit)", () => {
  it("legacy and missing grants keep both affordances (the server decides by role)", () => {
    expect(inboxAffordances(undefined)).toEqual({ canReply: true, canTake: true });
    expect(inboxAffordances(EMPTY_INDIVIDUAL)).toEqual({ canReply: true, canTake: true });
  });
  it("view only: neither", () => expect(inboxAffordances(ind({ view: true }))).toEqual({ canReply: false, canTake: false }));
  it("view + add: reply, no take", () => expect(inboxAffordances(ind({ view: true, add: true }))).toEqual({ canReply: true, canTake: false }));
  it("view + edit: take, no reply", () => expect(inboxAffordances(ind({ view: true, edit: true }))).toEqual({ canReply: false, canTake: true }));
  it("view + add + edit: both", () => expect(inboxAffordances(ind({ view: true, add: true, edit: true }))).toEqual({ canReply: true, canTake: true }));
  it("add + edit without view: neither (view is required)", () => expect(inboxAffordances(ind({ add: true, edit: true }))).toEqual({ canReply: false, canTake: false }));
  it("an individual account with no inbox row: neither", () => expect(inboxAffordances({ ...ind({}), pages: {} })).toEqual({ canReply: false, canTake: false }));
});
