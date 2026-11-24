import { canonicalPermissionPage } from "./permissionPageIds";
import { PAGES } from "./nav";
export const PAGE_ACTIONS = ["view", "add", "edit", "delete", "export"] as const;
export type PageAction = typeof PAGE_ACTIONS[number];
export type PageGrants = Record<string, Partial<Record<PageAction, boolean>>>;
export interface IndividualPermissions { mode: "legacy" | "individual"; revision: number; pages: PageGrants; sensitive: readonly string[]; homePage: string | null }
export const EMPTY_INDIVIDUAL: IndividualPermissions = { mode: "legacy", revision: 0, pages: {}, sensitive: [], homePage: null };
const KNOWN = new Set(PAGES.map(p => p.path));
export function individualAllows(grants: IndividualPermissions, path: string, action: PageAction): boolean {
 if (grants.mode !== "individual" || !KNOWN.has(path)) return false;
 const page = grants.pages[canonicalPermissionPage(path)]; return page?.view === true && (action === "view" || page[action] === true);
}
export function validatePageGrants(value: unknown): value is PageGrants {
 if (!value || typeof value !== "object" || Array.isArray(value)) return false;
 for (const [path, row] of Object.entries(value)) {
  if (!KNOWN.has(path) || !row || typeof row !== "object" || Array.isArray(row)) return false;
  for (const [action, allowed] of Object.entries(row)) if (!(PAGE_ACTIONS as readonly string[]).includes(action) || typeof allowed !== "boolean") return false;
  if (Object.entries(row).some(([a, v]) => a !== "view" && v === true) && row.view !== true) return false;
 }
 return true;
}

export function parseIndividualPermissions(value: unknown): IndividualPermissions {
 if (value === undefined) return EMPTY_INDIVIDUAL; // server predating individual grants
 if (!value || typeof value !== "object") throw new Error("Invalid page access response");
 const data = value as Record<string, unknown>;
 if (data.mode === "legacy" || data.mode === "none") return EMPTY_INDIVIDUAL;
 if (data.mode !== "individual" || !validatePageGrants(data.pages) || !Array.isArray(data.sensitive) || !data.sensitive.every(v => typeof v === "string") || !Number.isSafeInteger(data.revision) || (data.revision as number) < 1) throw new Error("Invalid individual grants");
 return { mode: "individual", pages: data.pages, sensitive: data.sensitive, revision: data.revision as number, homePage: typeof data.home_page === "string" ? data.home_page : null };
}
