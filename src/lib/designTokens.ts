/**
 * Plan 3.2 — ملف الرموز الواحد: the single token file of the approved RoomAI design system (owner approval
 * 2026-11-24, relayed by main; values verbatim from the approved tokens.json v1 — never edited here).
 * Every color, spacing, radius, shadow, font and size comes from this file; a literal in a component is a
 * violation of the style rule (scripts/check-design-tokens.mjs).
 *
 * Two themes: نهار (light) and ليل (dark). rgba grounds (surface-sunken, sand-sheer) are measured for contrast
 * on their documented composites over paper: ≈ #F7F3ED and ≈ #FAF6F0 (tokens.json usage notes).
 */

export type Theme = "light" | "dark";

export interface ThemedColor {
  light: string;
  dark: string;
  usage: string;
}

/** The 28 color tokens, verbatim from the approved tokens.json. */
export const colors = {
  paper: { light: "#fffffe", dark: "#435054", usage: "Page ground, staff pages: the lightest ground." },
  surface: { light: "#ffffff", dark: "#112830", usage: "Cards, tables, dialogs, fields." },
  "surface-sunken": { light: "rgba(241,235,225,0.6)", dark: "#17323a", usage: "Menus' ground (sidebar, top bar, phone tab bar), 16px backdrop blur (rai-menu). ≈ #F7F3ED over paper." },
  line: { light: "#e2d9cb", dark: "#24434c", usage: "Hairlines and dividers (decoration only, never a control border)." },
  "line-strong": { light: "#8c8170", dark: "#0b1f24", usage: "Borders of fields, check boxes and controls (3:1 on surface)." },
  ink: { light: "#10262d", dark: "#ecf2f1", usage: "Body text and headings on paper and surface." },
  "ink-muted": { light: "#5a6a6d", dark: "#a6b8b9", usage: "Secondary text, hints, captions (4.5:1 on paper and surface)." },
  night: { light: "#10343f", dark: "#cfe6e8", usage: "ليل — the brand: primary buttons, the sidebar's active item, the mark's arch." },
  "on-night": { light: "#ffffff", dark: "#5c6061", usage: "Text and icons on night." },
  spark: { light: "#0fa3b1", dark: "#38c6d2", usage: "نسيم — the AI touch, for the assistant alone. Large shapes and icons only (3:1)." },
  "spark-text": { light: "#0b6f78", dark: "#4bafb7", usage: "Text in the AI touch: «اقتراح من المساعد»." },
  "spark-tint": { light: "#e3f6f7", dark: "#2a585f", usage: "The ground of an AI suggestion card or chip." },
  saffron: { light: "#d9952b", dark: "#e8ae4c", usage: "زعفران — hospitality: the guest's welcome, ratings, a reserved unit. Shapes and icons only." },
  "saffron-text": { light: "#875812", dark: "#f0c27a", usage: "Text in the hospitality colour." },
  "saffron-tint": { light: "#f2f0ed", dark: "#3a2a10", usage: "The ground of a welcome note or a reserved badge." },
  sand: { light: "#f4ede2", dark: "#2a241b", usage: "رمل — warm relief blocks, the cover's doorways, the reversed mark's arch." },
  "sand-sheer": { light: "rgba(244,237,226,0.5)", dark: "#2a241b", usage: "Guest pages' ground: sand made half sheer, ≈ #FAF6F0 over paper. Cards on it stay surface." },
  success: { light: "#276e3d", dark: "#6ccb8a", usage: "Done, paid, available: text and icons." },
  "success-tint": { light: "#e5f3e9", dark: "#133222", usage: "Ground of a success badge or notice." },
  warning: { light: "#8a5300", dark: "#f1b85a", usage: "Needs attention: cleaning due, a balance left: text and icons." },
  "warning-tint": { light: "#e8e5e0", dark: "#3a2a0b", usage: "Ground of a warning badge or notice." },
  danger: { light: "#d21606", dark: "#f08a7e", usage: "Refused, failed, destructive: text, icons, the danger button." },
  "danger-tint": { light: "#fbe8e6", dark: "#3d1612", usage: "Ground of an error notice." },
  sky: { light: "#2f6db0", dark: "#7fb0ea", usage: "A unit being cleaned; information that is not the assistant's." },
  "sky-tint": { light: "#e6eff9", dark: "#13283f", usage: "Ground of a cleaning badge." },
  stone: { light: "#5f686a", dark: "#9aa6a8", usage: "Out of service, archived, disabled: text and icons." },
  "stone-tint": { light: "#eef0f0", dark: "#1c2b2f", usage: "Ground of an out-of-service badge." },
  focus: { light: "#0b6f78", dark: "#6fdce5", usage: "Focus ring, 2px, outside the control (3:1 on every ground)." },
} as const satisfies Record<string, ThemedColor>;

export type ColorToken = keyof typeof colors;

/** Documented composites of the sheer grounds over paper (tokens.json usage notes) — for contrast measurement. */
export const composites = {
  light: { "surface-sunken": "#f7f3ed", "sand-sheer": "#faf6f0" },
} as const;

export const fontFamilies = {
  display: '"Readex Pro", "IBM Plex Sans Arabic", system-ui, sans-serif',
  sans: '"IBM Plex Sans Arabic", "Noto Sans Arabic", system-ui, sans-serif',
  mono: '"IBM Plex Mono", ui-monospace, monospace',
} as const;

export interface TextStyle {
  fontSize: string;
  lineHeight: string;
  fontWeight: string;
  family: keyof typeof fontFamilies;
  usage: string;
}

export const textStyles = {
  "display-l": { fontSize: "40px", lineHeight: "48px", fontWeight: "600", family: "display", usage: "One per screen at most: the guest's welcome, the sign-in page." },
  "display-m": { fontSize: "32px", lineHeight: "40px", fontWeight: "600", family: "display", usage: "Big numbers on the start-of-shift board." },
  "title-l": { fontSize: "24px", lineHeight: "32px", fontWeight: "600", family: "display", usage: "Page title." },
  "title-m": { fontSize: "20px", lineHeight: "28px", fontWeight: "600", family: "display", usage: "Section and dialog title." },
  "body-l": { fontSize: "16px", lineHeight: "26px", fontWeight: "400", family: "sans", usage: "Guest pages and long reading." },
  "body-m": { fontSize: "14px", lineHeight: "22px", fontWeight: "400", family: "sans", usage: "Staff screens, tables, forms." },
  label: { fontSize: "13px", lineHeight: "18px", fontWeight: "500", family: "sans", usage: "Field labels, buttons, tabs." },
  caption: { fontSize: "12px", lineHeight: "16px", fontWeight: "400", family: "sans", usage: "Hints, time stamps, the guest footer." },
  code: { fontSize: "14px", lineHeight: "20px", fontWeight: "500", family: "mono", usage: "Booking and voucher numbers, key-box codes." },
} as const satisfies Record<string, TextStyle>;

export const spacing = {
  "space-1": "4px",
  "space-2": "8px",
  "space-3": "12px",
  "space-4": "16px",
  "space-5": "24px",
  "space-6": "32px",
  "space-7": "48px",
} as const;

export const radii = {
  "radius-sm": "6px",
  "radius-md": "10px",
  "radius-lg": "16px",
  "radius-xl": "28px",
  "radius-pill": "999px",
} as const;

export const shadows = {
  "shadow-1": { light: "0 1px 3px 2px #1017190f, 0 1px 1px rgba(16,38,45,0.04)", dark: "0 1px 2px rgba(0,0,0,0.40)" },
  "shadow-2": { light: "0 8px 24px 2px rgba(16,38,45,0.10)", dark: "0 8px 24px #12111180" },
} as const;

export const sizes = {
  "target-min": "44px",
  "field-height": "40px",
} as const;

/** The product name, one word, R and A and I capital (README «الاسم»). */
export const PRODUCT_NAME = "RoomAI";
/** The guest footer line: the only RoomAI appearance on guest pages (GuestBrand). */
export const POWERED_BY = "يعمل بـ RoomAI";

export interface DeclaredPair {
  label: string;
  theme: Theme;
  text: string;
  background: string;
  /** 4.5 for text (AA 1.4.3), 3 for control borders, focus ring and large shapes (1.4.11). */
  minimum: number;
}

/** Every text/background pair the system declares, measured on the documented grounds (3.2 gate). */
export const declaredPairs: DeclaredPair[] = [
  { label: "ink على paper", theme: "light", text: colors.ink.light, background: colors.paper.light, minimum: 4.5 },
  { label: "ink على surface", theme: "light", text: colors.ink.light, background: colors.surface.light, minimum: 4.5 },
  { label: "ink على القوائم (surface-sunken ≈ #F7F3ED)", theme: "light", text: colors.ink.light, background: composites.light["surface-sunken"], minimum: 4.5 },
  { label: "ink-muted على paper", theme: "light", text: colors["ink-muted"].light, background: colors.paper.light, minimum: 4.5 },
  { label: "ink-muted على surface", theme: "light", text: colors["ink-muted"].light, background: colors.surface.light, minimum: 4.5 },
  { label: "ink-muted على القوائم (surface-sunken ≈ #F7F3ED)", theme: "light", text: colors["ink-muted"].light, background: composites.light["surface-sunken"], minimum: 4.5 },
  { label: "ink-muted على أرضية النزيل (sand-sheer ≈ #FAF6F0)", theme: "light", text: colors["ink-muted"].light, background: composites.light["sand-sheer"], minimum: 4.5 },
  { label: "on-night على night", theme: "light", text: colors["on-night"].light, background: colors.night.light, minimum: 4.5 },
  { label: "spark-text على spark-tint", theme: "light", text: colors["spark-text"].light, background: colors["spark-tint"].light, minimum: 4.5 },
  { label: "saffron-text على saffron-tint", theme: "light", text: colors["saffron-text"].light, background: colors["saffron-tint"].light, minimum: 4.5 },
  { label: "success على success-tint", theme: "light", text: colors.success.light, background: colors["success-tint"].light, minimum: 4.5 },
  { label: "warning على warning-tint", theme: "light", text: colors.warning.light, background: colors["warning-tint"].light, minimum: 4.5 },
  { label: "danger على danger-tint", theme: "light", text: colors.danger.light, background: colors["danger-tint"].light, minimum: 4.5 },
  { label: "sky على sky-tint", theme: "light", text: colors.sky.light, background: colors["sky-tint"].light, minimum: 4.5 },
  { label: "stone على stone-tint", theme: "light", text: colors.stone.light, background: colors["stone-tint"].light, minimum: 4.5 },
  { label: "حدود الحقول line-strong على surface", theme: "light", text: colors["line-strong"].light, background: colors.surface.light, minimum: 3 },
  { label: "حلقة التركيز focus على paper", theme: "light", text: colors.focus.light, background: colors.paper.light, minimum: 3 },
  { label: "شكل spark على paper", theme: "light", text: colors.spark.light, background: colors.paper.light, minimum: 3 },
  { label: "شكل saffron على paper", theme: "light", text: colors.saffron.light, background: colors.paper.light, minimum: 3 },
  { label: "ink على paper (ليل)", theme: "dark", text: colors.ink.dark, background: colors.paper.dark, minimum: 4.5 },
  { label: "ink على surface (ليل)", theme: "dark", text: colors.ink.dark, background: colors.surface.dark, minimum: 4.5 },
  { label: "ink-muted على paper (ليل)", theme: "dark", text: colors["ink-muted"].dark, background: colors.paper.dark, minimum: 4.5 },
  { label: "ink-muted على surface (ليل)", theme: "dark", text: colors["ink-muted"].dark, background: colors.surface.dark, minimum: 4.5 },
  { label: "on-night على night (ليل)", theme: "dark", text: colors["on-night"].dark, background: colors.night.dark, minimum: 4.5 },
  { label: "spark-text على spark-tint (ليل)", theme: "dark", text: colors["spark-text"].dark, background: colors["spark-tint"].dark, minimum: 4.5 },
  { label: "saffron-text على saffron-tint (ليل)", theme: "dark", text: colors["saffron-text"].dark, background: colors["saffron-tint"].dark, minimum: 4.5 },
  { label: "success على success-tint (ليل)", theme: "dark", text: colors.success.dark, background: colors["success-tint"].dark, minimum: 4.5 },
  { label: "warning على warning-tint (ليل)", theme: "dark", text: colors.warning.dark, background: colors["warning-tint"].dark, minimum: 4.5 },
  { label: "danger على danger-tint (ليل)", theme: "dark", text: colors.danger.dark, background: colors["danger-tint"].dark, minimum: 4.5 },
  { label: "sky على sky-tint (ليل)", theme: "dark", text: colors.sky.dark, background: colors["sky-tint"].dark, minimum: 4.5 },
  { label: "stone على stone-tint (ليل)", theme: "dark", text: colors.stone.dark, background: colors["stone-tint"].dark, minimum: 4.5 },
  { label: "حدود الحقول line-strong على surface (ليل)", theme: "dark", text: colors["line-strong"].dark, background: colors.surface.dark, minimum: 3 },
  { label: "حلقة التركيز focus على paper (ليل)", theme: "dark", text: colors.focus.dark, background: colors.paper.dark, minimum: 3 },
];

/**
 * Approved values that do NOT meet their declared contrast — recorded, never claimed as AA (owner/main flag
 * 2026-11-24, and the 3.2 gate's own measurements). Exact values stay pending a design decision; any consumer
 * must surface the same warning. Each entry names its measured ratio so a silent value change fails the test.
 */
export const knownContrastExceptions = [
  { label: "ink-muted على paper (ليل)", ratio: 4.05, minimum: 4.5, note: "مُبلَّغ عنه مع الاعتماد: 4.0:1 — لا يُدَّعى له AA" },
  { label: "spark-text على spark-tint (ليل)", ratio: 3.05, minimum: 4.5, note: "وجدته بوابة 3.2 عند القياس — نص الذكاء على أرضيته في الليل" },
  { label: "شكل saffron على paper", ratio: 2.53, minimum: 3, note: "وجدته بوابة 3.2: الزعفران للأشكال بحد أدنى 3:1 ولا يحققه على paper" },
  { label: "حدود الحقول line-strong على surface (ليل)", ratio: 1.11, minimum: 3, note: "وجدته بوابة 3.2: حدود الحقول في الليل شبه غائبة عن surface" },
] as const;
