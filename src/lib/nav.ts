/**
 * Single source of truth for which staff role may open which page (A08).
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
}

export const PAGES: readonly NavPage[] = [
  // ---- staff (operations centre) — order = navigation order ----
  { path: "/staff/dashboard", label: "لوحة العمليات", icon: LayoutDashboard, area: "staff", roles: ALL_STAFF },
  { path: "/staff/arrivals", label: "وصول اليوم", icon: CalendarClock, area: "staff", roles: ALL_STAFF, navRoles: MONEY_ROLES },
  { path: "/staff/reservations", label: "الحجوزات", icon: BookCheck, area: "staff", roles: ALL_STAFF, navRoles: MONEY_ROLES },
  { path: "/staff/reservations/new", label: "حجز جديد", icon: BookCheck, area: "staff", roles: ["owner", "manager", "supervisor"], hidden: true },
  { path: "/staff/reservations/:id", label: "تفاصيل الحجز", icon: BookCheck, area: "staff", roles: ALL_STAFF, hidden: true },
  { path: "/staff/identity-verification", label: "مطابقة الهويات", icon: UserCheck, area: "staff", roles: MONEY_ROLES },
  { path: "/staff/payments", label: "المدفوعات", icon: CreditCard, area: "staff", roles: MONEY_ROLES },
  { path: "/staff/access-approvals", label: "اعتماد الدخول", icon: KeyRound, area: "staff", roles: MONEY_ROLES },
  { path: "/staff/rooms", label: "لوحة الوحدات", icon: DoorClosed, area: "staff", roles: ALL_STAFF },
  { path: "/staff/housekeeping", label: "خدمة الغرف", icon: Sparkles, area: "staff", roles: ALL_STAFF },
  { path: "/staff/codes", label: "الرموز", icon: KeyRound, area: "staff", roles: CODES_ROLES },
  { path: "/staff/tickets", label: "البلاغات", icon: Wrench, area: "staff", roles: ALL_STAFF },
  { path: "/staff/inbox", label: "الوارد", icon: Inbox, area: "staff", roles: ALL_STAFF, navRoles: MONEY_ROLES },

  // ---- admin — order within a group = navigation order ----
  { path: "/admin/dashboard", label: "لوحة الإدارة", icon: LayoutDashboard, area: "admin", group: "نظرة عامة", roles: ADMIN_ROLES },

  { path: "/admin/branches", label: "الفروع", icon: Building2, area: "admin", group: "المنشآت", roles: ADMIN_ROLES, scope: "org" },
  { path: "/admin/structure", label: "البلوكات والطوابق", icon: Layers, area: "admin", group: "المنشآت", roles: ADMIN_ROLES },
  { path: "/admin/room-categories", label: "أنواع الوحدات", icon: BedDouble, area: "admin", group: "المنشآت", roles: ADMIN_ROLES },
  { path: "/admin/rooms", label: "الوحدات", icon: DoorClosed, area: "admin", group: "المنشآت", roles: ADMIN_ROLES },
  { path: "/admin/facilities", label: "المرافق", icon: Landmark, area: "admin", group: "المنشآت", roles: ADMIN_ROLES },
  { path: "/admin/task-types", label: "أنواع المهام", icon: ListChecks, area: "admin", group: "المنشآت", roles: ADMIN_ROLES },
  { path: "/admin/services", label: "الخدمات", icon: ConciergeBell, area: "admin", group: "المنشآت", roles: ADMIN_ROLES },
  { path: "/admin/availability", label: "التوفر", icon: CalendarRange, area: "admin", group: "المنشآت", roles: ADMIN_ROLES },
  { path: "/admin/availability-rules", label: "قواعد الكشف", icon: CalendarRange, area: "admin", group: "المنشآت", roles: ADMIN_ROLES },

  { path: "/admin/reservations", label: "الحجوزات", icon: BookCheck, area: "admin", group: "العمليات", roles: ADMIN_OPS },
  { path: "/admin/guests", label: "النزلاء", icon: Users, area: "admin", group: "العمليات", roles: ADMIN_OPS },
  { path: "/admin/finance", label: "المالية", icon: Wallet, area: "admin", group: "العمليات", roles: ADMIN_FINANCE },
  // the key boxes moved to the one screen «الرموز» (/staff/codes); the old address still leads there
  { path: "/admin/keyboxes", label: "الرموز", icon: KeyRound, area: "admin", roles: CODES_ROLES, hidden: true },

  { path: "/admin/staff", label: "الموظفون", icon: UserCog, area: "admin", group: "الإدارة", roles: ADMIN_ROLES, scope: "org" },
  { path: "/admin/roles", label: "الصلاحيات", icon: ShieldCheck, area: "admin", group: "الإدارة", roles: ADMIN_ROLES, scope: "org" },
  { path: "/admin/booking-sources", label: "منصات الحجز", icon: Link2, area: "admin", group: "الإدارة", roles: ADMIN_ROLES, scope: "org" },

  { path: "/admin/ai-settings", label: "إعدادات الذكاء الاصطناعي", icon: Bot, area: "admin", group: "التكاملات", roles: ADMIN_ROLES, scope: "org" },
  { path: "/admin/whatsapp", label: "واتساب الفروع", icon: MessageCircle, area: "admin", group: "التكاملات", roles: ["owner"], scope: "org" },
  { path: "/admin/assistant", label: "تجربة المساعد", icon: MessagesSquare, area: "admin", group: "التكاملات", roles: ["owner", "manager", "supervisor"] },
  { path: "/admin/payment-providers", label: "مزودو الدفع", icon: CreditCard, area: "admin", group: "التكاملات", roles: ADMIN_ROLES, scope: "org" },
  { path: "/admin/integrations", label: "التكاملات", icon: Plug, area: "admin", group: "التكاملات", roles: ADMIN_ROLES, scope: "org" },

  { path: "/admin/knowledge", label: "قاعدة المعرفة", icon: BookOpen, area: "admin", group: "الحوكمة", roles: ["owner", "manager", "supervisor"] },
  { path: "/admin/policies", label: "السياسات", icon: FileText, area: "admin", group: "الحوكمة", roles: ["owner", "manager", "supervisor"] },
  { path: "/admin/reports", label: "التقارير", icon: BarChart3, area: "admin", group: "الحوكمة", roles: ADMIN_FINANCE },
  { path: "/admin/audit-logs", label: "سجل الإجراءات", icon: ScrollText, area: "admin", group: "الحوكمة", roles: ADMIN_FINANCE },
  { path: "/admin/data-purge", label: "تفريغ البيانات", icon: Trash2, area: "admin", group: "الحوكمة", roles: ["owner"], scope: "org" },
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

/** May this role open the page at `pathname`? Unknown routes under a guarded layout are denied (fail closed). */
export function canOpen(role: string | null | undefined, pathname: string): boolean {
  const page = pageFor(pathname);
  return !!page && includes(page.roles, role);
}

/** Staff sidebar / top bar links for a role, in table order. */
export function staffNav(role: string | null | undefined): NavPage[] {
  return PAGES.filter((p) => p.area === "staff" && !p.hidden && includes(p.navRoles ?? p.roles, role));
}

/** Admin sidebar groups for a role; empty groups are dropped. */
export function adminNav(role: string | null | undefined): Array<{ title: string; items: NavPage[] }> {
  const items = PAGES.filter((p) => p.area === "admin" && !p.hidden && includes(p.navRoles ?? p.roles, role));
  return ADMIN_GROUP_ORDER.map((title) => ({ title, items: items.filter((p) => p.group === title) })).filter((g) => g.items.length > 0);
}

/** First admin page the role may open (used for the "لوحة الإدارة ↗" link), or null if none. */
export function firstAdminPath(role: string | null | undefined): string | null {
  return adminNav(role)[0]?.items[0]?.path ?? null;
}

export const hasAdminAccess = (role: string | null | undefined) => firstAdminPath(role) !== null;

/**
 * Where a role lands after signing in: the screen where its work starts (fewest clicks to the first task).
 * housekeeping → its task list; finance → the ledger; front office and management → the operations board.
 */
export function homeFor(role: string | null | undefined): string {
  if (role === "housekeeping") return "/staff/housekeeping";
  if (role === "finance") return "/admin/finance";
  return "/staff/dashboard";
}
