/**
 * Single source of truth for which staff role may open which page (GAP08).
 *
 * The same table drives three things so they can never disagree:
 *   1. the route guard (`RequireRole`): `roles` = who may open the page;
 *   2. the navigation of both layouts: `navRoles` (defaults to `roles`) = who sees the link;
 *   3. whether a page needs an authorised branch (`scope: "branch"`, the default) or works at
 *      organisation level (`scope: "org"`, e.g. the branches page an owner uses to create the first branch).
 *
 * The server keeps enforcing every rule (RLS + SECURITY DEFINER RPCs); this is UX and defence in depth.
 */
import { matchPath } from "react-router-dom";
import type { LucideIcon } from "lucide-react";
import {
  LayoutDashboard, CalendarClock, BookCheck, UserCheck, CreditCard, KeyRound, DoorClosed, Sparkles, Wrench, Inbox,
  Building2, BedDouble, CalendarRange, Users, Wallet, UserCog, ShieldCheck, Link2, Bot, MessageCircle, FileText,
  BarChart3, ScrollText, Plug, Layers, Landmark, ListChecks, ConciergeBell, BookOpen, Trash2, MessagesSquare,
  Calculator, Vault, HandCoins, ClipboardList, BellRing, ClipboardCheck, Activity,
} from "lucide-react";
import type { Role } from "./types";

export type StaffRole = Exclude<Role, "guest">;

export const ALL_STAFF: readonly StaffRole[] = ["owner", "manager", "supervisor", "finance", "housekeeping"];
/** Roles that may see money (mirrors MONEY_ROLES on the server). */
export const MONEY_ROLES: readonly StaffRole[] = ["owner", "manager", "supervisor", "finance"];
export const ADMIN_ROLES: readonly StaffRole[] = ["owner", "manager"];
/** «الرموز» — key-box codes: the supervisor and housekeeping (who change them after each departure), and management. */
export const CODES_ROLES: readonly StaffRole[] = ["owner", "manager", "supervisor", "housekeeping"];
const ADMIN_FINANCE: readonly StaffRole[] = ["owner", "manager", "finance"];
const ADMIN_OPS: readonly StaffRole[] = ["owner", "manager", "supervisor", "finance"];

export interface NavPage {
  /** react-router pattern, e.g. "/staff/reservations/:id" */
  path: string;
  label: string;
  icon: LucideIcon;
  area: "staff" | "admin";
  /** Who may open the route. */
  roles: readonly StaffRole[];
  /** Who sees the link in navigation (defaults to `roles`). A page can be reachable but not advertised. */
  navRoles?: readonly StaffRole[];
  /** Never shown in navigation (detail / create pages). */
  hidden?: boolean;
  /** "branch" (default): needs at least one authorised branch; "org": works without one. */
  scope?: "branch" | "org";
  /** Admin sidebar group title. */
  group?: string;
  /**
   * The operations of the permissions matrix the page serves (decision 71): when set, a person other than the owner may
   * open the page — and sees its link — when the matrix allows any of them (with `capFull`, without the cell's
   * condition). With the approved matrix this is exactly `roles` (tests/unit/nav.test.ts NV01).
   */
  cap?: readonly string[];
  capFull?: boolean;
}

export const PAGES: readonly NavPage[] = [
  // ---- staff (operations centre) — order = navigation order ----
  // B11 (note 12, decision 5): the units board comes first — the front desk's first page
  { path: "/staff/rooms", label: "لوحة الوحدات", icon: DoorClosed, area: "staff", roles: ALL_STAFF },
  { path: "/staff/dashboard", label: "لوحة العمليات", icon: LayoutDashboard, area: "staff", roles: ALL_STAFF },
  { path: "/staff/arrivals", label: "وصول اليوم", icon: CalendarClock, area: "staff", roles: ALL_STAFF, navRoles: MONEY_ROLES },
  { path: "/staff/reservations", label: "الحجوزات", icon: BookCheck, area: "staff", roles: ALL_STAFF, navRoles: MONEY_ROLES },
  { path: "/staff/reservations/new", label: "حجز جديد", icon: BookCheck, area: "staff", roles: ["owner", "manager", "supervisor"], hidden: true, cap: ["res.create"] },
  { path: "/staff/reservations/:id", label: "تفاصيل الحجز", icon: BookCheck, area: "staff", roles: ALL_STAFF, hidden: true },
  { path: "/staff/identity-verification", label: "مطابقة الهويات", icon: UserCheck, area: "staff", roles: MONEY_ROLES },
  { path: "/staff/payments", label: "المدفوعات", icon: CreditCard, area: "staff", roles: MONEY_ROLES },
  // decision 13: the day's terminal total against the terminal vouchers (§16: owner, manager, supervisor, finance)
  { path: "/staff/pos-settlement", label: "تسوية الشبكة", icon: Calculator, area: "staff", roles: MONEY_ROLES, cap: ["pos.settle"] },
  { path: "/staff/access-approvals", label: "الوصول وتسليم الرمز", icon: KeyRound, area: "staff", roles: MONEY_ROLES },
  // 0033: the day's follow-up (overdue nights, departures not closed, late departures) and the per-employee day (decision 5)
  { path: "/staff/followups", label: "متابعة الإقامات", icon: BellRing, area: "staff", roles: MONEY_ROLES },
  // decision 4: today's and tomorrow's platform arrivals, matched against the platform (the supervisor's daily list)
  { path: "/staff/platforms", label: "مطابقة المنصات", icon: Link2, area: "staff", roles: ["owner", "manager", "supervisor"] },
  { path: "/staff/day-summary", label: "ملخص اليوم", icon: ClipboardList, area: "staff", roles: MONEY_ROLES },
  { path: "/staff/housekeeping", label: "خدمة الغرف", icon: Sparkles, area: "staff", roles: ALL_STAFF },
  { path: "/staff/codes", label: "الرموز", icon: KeyRound, area: "staff", roles: CODES_ROLES, cap: ["keybox.code"] },
  { path: "/staff/tickets", label: "البلاغات", icon: Wrench, area: "staff", roles: ALL_STAFF },
  { path: "/staff/inbox", label: "الوارد", icon: Inbox, area: "staff", roles: ALL_STAFF, navRoles: MONEY_ROLES },

  // ---- admin — order within a group = navigation order ----
  { path: "/admin/dashboard", label: "لوحة الإدارة", icon: LayoutDashboard, area: "admin", group: "نظرة عامة", roles: ADMIN_ROLES },

  { path: "/admin/branches", label: "الفروع", icon: Building2, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, scope: "org", cap: ["branch.settings"] },
  { path: "/admin/structure", label: "البلوكات والطوابق", icon: Layers, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, cap: ["definitions"] },
  { path: "/admin/room-categories", label: "أنواع الوحدات", icon: BedDouble, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, cap: ["definitions"] },
  { path: "/admin/rooms", label: "الوحدات", icon: DoorClosed, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, cap: ["definitions"] },
  { path: "/admin/facilities", label: "المرافق", icon: Landmark, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, cap: ["definitions"] },
  { path: "/admin/task-types", label: "أنواع المهام", icon: ListChecks, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, cap: ["definitions"] },
  { path: "/admin/services", label: "الخدمات", icon: ConciergeBell, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, cap: ["definitions"] },
  // decision 33: one price calendar; «التوفر» and «قواعد الكشف» are hidden, their data kept and their pages still reachable
  { path: "/admin/rates", label: "تقويم الأسعار", icon: CalendarRange, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, cap: ["rates"] },
  { path: "/admin/availability", label: "التوفر", icon: CalendarRange, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, hidden: true },
  { path: "/admin/availability-rules", label: "قواعد الكشف", icon: CalendarRange, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, hidden: true },

  { path: "/admin/reservations", label: "الحجوزات", icon: BookCheck, area: "admin", group: "العمليات", roles: ADMIN_OPS },
  // decisions 2 and 21: guest profiles with search, ratings and bans (owner, manager, supervisor)
  { path: "/admin/guests", label: "النزلاء", icon: Users, area: "admin", group: "العمليات", roles: ["owner", "manager", "supervisor"] },
  { path: "/admin/guests/:id", label: "ملف الضيف", icon: Users, area: "admin", roles: ["owner", "manager", "supervisor"], hidden: true },

  { path: "/admin/finance", label: "المالية", icon: Wallet, area: "admin", group: "العمليات", roles: ADMIN_FINANCE },
  // decision 24: platform-collected payments matched to the platform's bank deposit (§16: owner, manager, finance)
  { path: "/admin/platform-payouts", label: "مطابقة المنصات", icon: HandCoins, area: "admin", group: "العمليات", roles: ADMIN_FINANCE, cap: ["platform.payouts"] },
  // decision 25: each branch's cash boxes and bank accounts (§16: owner, manager)
  { path: "/admin/cash-accounts", label: "الصناديق والحسابات", icon: Vault, area: "admin", group: "العمليات", roles: ADMIN_ROLES, cap: ["cash_accounts"] },
  // the key boxes moved to the one screen «الرموز» (/staff/codes); the old address still leads there
  { path: "/admin/keyboxes", label: "الرموز", icon: KeyRound, area: "admin", roles: CODES_ROLES, hidden: true },

  { path: "/admin/staff", label: "الموظفون", icon: UserCog, area: "admin", group: "الإدارة", roles: ADMIN_ROLES, scope: "org", cap: ["staff.manage", "staff.force_logout"] },
  // decision 71: the owner edits the approved matrix (the server: fn_permissions_matrix, fn_admin_set_permissions)
  { path: "/admin/roles", label: "مصفوفة الصلاحيات", icon: ShieldCheck, area: "admin", group: "الإدارة", roles: ["owner"], scope: "org", cap: ["admin.permissions"] },
  { path: "/admin/booking-sources", label: "منصات الحجز", icon: Link2, area: "admin", group: "الإدارة", roles: ADMIN_ROLES, scope: "org", cap: ["definitions"] },

  { path: "/admin/ai-settings", label: "إعدادات الذكاء الاصطناعي", icon: Bot, area: "admin", group: "التكاملات", roles: ADMIN_ROLES, scope: "org" },
  { path: "/admin/whatsapp", label: "واتساب الفروع", icon: MessageCircle, area: "admin", group: "التكاملات", roles: ["owner"], scope: "org", cap: ["security"] },
  { path: "/admin/assistant", label: "تجربة المساعد", icon: MessagesSquare, area: "admin", group: "التكاملات", roles: ["owner", "manager", "supervisor"] },
  { path: "/admin/payment-providers", label: "مزودو الدفع", icon: CreditCard, area: "admin", group: "التكاملات", roles: ADMIN_ROLES, scope: "org" },
  { path: "/admin/integrations", label: "التكاملات", icon: Plug, area: "admin", group: "التكاملات", roles: ADMIN_ROLES, scope: "org" },

  { path: "/admin/knowledge", label: "قاعدة المعرفة", icon: BookOpen, area: "admin", group: "الحوكمة", roles: ["owner", "manager", "supervisor"], cap: ["knowledge"] },
  { path: "/admin/policies", label: "السياسات", icon: FileText, area: "admin", group: "الحوكمة", roles: ["owner", "manager", "supervisor"] },
  { path: "/admin/reports", label: "التقارير", icon: BarChart3, area: "admin", group: "الحوكمة", roles: ADMIN_FINANCE, cap: ["reports.finance"], capFull: true },
  // decision 14 (10.3): the log is read through fn_audit_list — the owner, the manager and the supervisor (security rows for the owner alone)
  { path: "/admin/audit-logs", label: "سجل الإجراءات", icon: ScrollText, area: "admin", group: "الحوكمة", roles: ["owner", "manager", "supervisor"], cap: ["audit.log"] },
  // decision 55: «استعمال القدرات» from the audit log, for the owner
  { path: "/admin/usage", label: "استعمال القدرات", icon: Activity, area: "admin", group: "الحوكمة", roles: ["owner"], scope: "org", cap: ["reports.identities_usage"] },
  // §16: corrections, invoice edits and cancellations, and what the monitors find (decision 54) wait for the owner alone
  { path: "/admin/review", label: "بحاجة لمراجعة وتدقيق", icon: ClipboardCheck, area: "admin", group: "الحوكمة", roles: ["owner"], scope: "org", cap: ["review.list"] },
  { path: "/admin/data-purge", label: "تفريغ البيانات", icon: Trash2, area: "admin", group: "الحوكمة", roles: ["owner"], scope: "org", cap: ["security"] },
];

const ADMIN_GROUP_ORDER = ["نظرة عامة", "المنشآت", "العمليات", "الإدارة", "التكاملات", "الحوكمة"];

/** The table entry for a concrete pathname (most specific pattern wins), or undefined for an unknown route. */
export function pageFor(pathname: string): NavPage | undefined {
  const hits = PAGES.filter((p) => matchPath({ path: p.path, end: true }, pathname));
  if (hits.length === 0) return undefined;
  return hits.sort((a, b) => countParams(a.path) - countParams(b.path))[0];
}
const countParams = (pattern: string) => pattern.split("/").filter((s) => s.startsWith(":")).length;

const includes = (list: readonly StaffRole[], role: string | null | undefined) => !!role && (list as readonly string[]).includes(role);

/** What the matrix allows the person (useAuth().can / canFull); without it, the role alone decides. */
export interface Allows { can: (code: string) => boolean; canFull: (code: string) => boolean }

/** May this person open this page? The owner: the role table; others: the matrix where the page names operations. */
export function pageAllowed(page: NavPage, role: string | null | undefined, allows?: Allows): boolean {
  if (!role) return false;
  if (page.cap && allows && role !== "owner") return page.cap.some((c) => (page.capFull ? allows.canFull(c) : allows.can(c)));
  return includes(page.roles, role);
}
/** Does this person see the page's link? (a page can be reachable but not advertised: `navRoles`) */
function pageListed(page: NavPage, role: string | null | undefined, allows?: Allows): boolean {
  if (page.cap && allows && role !== "owner") return pageAllowed(page, role, allows);
  return includes(page.navRoles ?? page.roles, role);
}

/** May this role open the page at `pathname`? Unknown routes under a guarded layout are denied (fail closed). */
export function canOpen(role: string | null | undefined, pathname: string, allows?: Allows): boolean {
  const page = pageFor(pathname);
  return !!page && pageAllowed(page, role, allows);
}

/** Staff sidebar / top bar links for a role, in table order. */
export function staffNav(role: string | null | undefined, allows?: Allows): NavPage[] {
  return PAGES.filter((p) => p.area === "staff" && !p.hidden && pageListed(p, role, allows));
}

/** Admin sidebar groups for a role; empty groups are dropped. */
export function adminNav(role: string | null | undefined, allows?: Allows): Array<{ title: string; items: NavPage[] }> {
  const items = PAGES.filter((p) => p.area === "admin" && !p.hidden && pageListed(p, role, allows));
  return ADMIN_GROUP_ORDER.map((title) => ({ title, items: items.filter((p) => p.group === title) })).filter((g) => g.items.length > 0);
}

/** First admin page the role may open (used for the "لوحة الإدارة ↗" link), or null if none. */
export function firstAdminPath(role: string | null | undefined, allows?: Allows): string | null {
  return adminNav(role, allows)[0]?.items[0]?.path ?? null;
}

export const hasAdminAccess = (role: string | null | undefined, allows?: Allows) => firstAdminPath(role, allows) !== null;

/**
 * Where a role lands after signing in: the screen where its work starts (fewest clicks to the first task).
 * housekeeping → its task list; finance → the ledger; the supervisor (the front desk) → the units board (B11, the
 * owner's note 12); the owner and managers → the operations board.
 */
export function homeFor(role: string | null | undefined): string {
  if (role === "housekeeping") return "/staff/housekeeping";
  if (role === "finance") return "/admin/finance";
  if (role === "supervisor") return "/staff/rooms";
  return "/staff/dashboard";
}
