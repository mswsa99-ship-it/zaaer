import { describe, it, expect } from "vitest";
import { retainUnexpectedErrors } from "../e2e/scoped-network-errors";

describe("admin recovery console scope", () => {
  const message = "e2e admin-list refusal: /admin/services";
  const exact = `console.error: ${message}`;
  it("removes only exact console refusals inside the injection window", () => {
    const errors = [exact, exact, exact];
    retainUnexpectedErrors(errors, message, 1, 2);
    expect(errors).toEqual([exact, exact]);
  });
  it("retains unrelated errors, substring impostors, other routes and page exceptions", () => {
    const errors = ["console.error: unrelated sentinel", `${exact} unexpected`,
      "console.error: e2e admin-list refusal: /admin/rooms", `pageerror: ${message}`];
    const before = [...errors];
    retainUnexpectedErrors(errors, message, 0, errors.length);
    expect(errors).toEqual(before);
    expect(() => expect(errors).toEqual([])).toThrow();
  });
  it("does not drop anything when no console errors occurred", () => {
    const errors: string[] = [];
    retainUnexpectedErrors(errors, message, 0, 0);
    expect(errors).toEqual([]);
  });
});
