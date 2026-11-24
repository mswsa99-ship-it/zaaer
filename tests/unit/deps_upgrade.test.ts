// Plan 5.5: zod 4 / react-router 7 upgrade guards. Independent of app code: they pin the behaviour the app relies on.
import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToString } from "react-dom/server";
import { MemoryRouter, Routes, Route, Link, matchPath, generatePath, matchRoutes, useParams } from "react-router-dom";
import { z } from "zod";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const major = (name: string) => Number(String(require(`${name}/package.json`).version).split(".")[0]);

describe("installed majors (plan 5.5)", () => {
  it("zod is 4+ and react-router(-dom) is 7+", () => {
    expect(major("zod")).toBeGreaterThanOrEqual(4);
    expect(major("react-router")).toBeGreaterThanOrEqual(7);
    expect(major("react-router-dom")).toBeGreaterThanOrEqual(7);
  });
});

describe("zod 4 form validation", () => {
  const schema = z.object({ name: z.string().min(2), phone: z.string().regex(/^05\d{8}$/), nights: z.coerce.number().int().min(1).max(30) });
  it("accepts a valid form and coerces numbers", () => {
    const r = schema.safeParse({ name: "محمد", phone: "0541997799", nights: "3" });
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.nights).toBe(3);
  });
  it("rejects bad fields with a path per field", () => {
    const r = schema.safeParse({ name: "م", phone: "123", nights: "0" });
    expect(r.success).toBe(false);
    if (!r.success) expect(r.error.issues.map((i) => i.path[0]).sort()).toEqual(["name", "nights", "phone"]);
  });
  it("bounded collections still validate", () => {
    const arr = z.array(z.number()).max(3);
    expect(arr.safeParse([1, 2, 3]).success).toBe(true);
    expect(arr.safeParse([1, 2, 3, 4]).success).toBe(false);
  });
});

describe("react-router 7 routing", () => {
  it("matches params and builds paths", () => {
    expect(matchPath("/booking/status/:token", "/booking/status/abc")?.params.token).toBe("abc");
    expect(generatePath("/staff/reservations/:id", { id: "7" })).toBe("/staff/reservations/7");
    expect(matchRoutes([{ path: "/admin/*" }], "/admin/finance")).not.toBeNull();
  });
  it("renders routes and links under MemoryRouter", () => {
    const Show = () => createElement("b", null, useParams().id);
    const html = renderToString(
      createElement(MemoryRouter, { initialEntries: ["/r/42"] },
        createElement(Link, { to: "/staff" }, "go"),
        createElement(Routes, null, createElement(Route, { path: "/r/:id", element: createElement(Show) }))),
    );
    expect(html).toContain("42");
    expect(html).toContain('href="/staff"');
  });
});
