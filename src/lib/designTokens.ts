/** Shared theme values. CSS consumers use src/tokens.css. Keep both palettes in sync. */

export type Theme = "light" | "dark";

export interface ThemedColor {
  light: string;
  dark: string;
  usage: string;
}

/** Shared theme colour tokens, with day/night values. */
export const colors = {
  paper: { light: "#f5f7fa", dark: "#091c24", usage: "Page ground, staff pages: the lightest ground." },
  surface: { light: "#ffffff", dark: "#112b35", usage: "Cards, tables, dialogs, fields." },
  "surface-sunken": { light: "#e5edf0", dark: "#183b47", usage: "Selected surface and recessed areas." },
  line: { light: "#d2dfe3", dark: "#37525c", usage: "Hairlines and dividers (decoration only, never a control border)." },
  "line-strong": { light: "#607c86", dark: "#8babb6", usage: "Borders of fields, check boxes and controls (3:1 on surface)." },
  "field-fill": { light: "#ffffff", dark: "#244a54", usage: "Owner-approved night filled fields, no visible border." },
  "field-ink": { light: "#10262d", dark: "#f8fbfb", usage: "Text inside filled fields." },
  ink: { light: "#10262d", dark: "#f8fbfb", usage: "Body text and headings on paper and surface." },
  "ink-muted": { light: "#354d55", dark: "#eaf1f2", usage: "Secondary text, hints, captions (4.5:1 on paper and surface)." },
  night: { light: "#e5edf0", dark: "#183b47", usage: "Legacy action surface alias, follows the active theme." },
  "on-night": { light: "#095865", dark: "#daf8fb", usage: "Text and icons on night." },
  spark: { light: "#095865", dark: "#daf8fb", usage: "نسيم — the AI touch, for the assistant alone. Large shapes and icons only (3:1)." },
  "spark-text": { light: "#3e4678", dark: "#e9e7ff", usage: "Text in the AI touch: «اقتراح من المساعد»." },
  "spark-tint": { light: "#e8e8f5", dark: "#33304e", usage: "The ground of an AI suggestion card or chip." },
  saffron: { light: "#624000", dark: "#fff0d3", usage: "زعفران — hospitality: the guest's welcome, ratings, a reserved unit. Shapes and icons only." },
  "saffron-text": { light: "#624000", dark: "#fff0d3", usage: "Text in the hospitality colour." },
  "saffron-tint": { light: "#f7ead2", dark: "#49350e", usage: "The ground of a welcome note or a reserved badge." },
  sand: { light: "#f5f7fa", dark: "#091c24", usage: "رمل — warm relief blocks, the cover's doorways, the reversed mark's arch." },
  "sand-sheer": { light: "#f5f7fa", dark: "#112b35", usage: "Guest pages' ground: sand made half sheer, ≈ #FAF6F0 over paper. Cards on it stay surface." },
  success: { light: "#155b30", dark: "#d1f4db", usage: "Done, paid, available: text and icons." },
  "success-tint": { light: "#dcefe2", dark: "#193f2a", usage: "Ground of a success badge or notice." },
  warning: { light: "#624000", dark: "#fff0d3", usage: "Needs attention: cleaning due, a balance left: text and icons." },
  "warning-tint": { light: "#f7ead2", dark: "#49350e", usage: "Ground of a warning badge or notice." },
  danger: { light: "#92190f", dark: "#ffddd7", usage: "Refused, failed, destructive: text, icons, the danger button." },
  "danger-tint": { light: "#f8e2df", dark: "#4b201b", usage: "Ground of an error notice." },
  sky: { light: "#095865", dark: "#daf8fb", usage: "A unit being cleaned; information that is not the assistant's." },
  "sky-tint": { light: "#dfeef2", dark: "#173f49", usage: "Ground of a cleaning badge." },
  stone: { light: "#354d55", dark: "#eaf1f2", usage: "Out of service, archived, disabled: text and icons." },
  "stone-tint": { light: "#e5edf0", dark: "#183b47", usage: "Ground of an out-of-service badge." },
  focus: { light: "#095865", dark: "#daf8fb", usage: "Focus ring, 2px, outside the control (3:1 on every ground)." },
} as const satisfies Record<string, ThemedColor>;

export type ColorToken = keyof typeof colors;

/** Shared opaque grounds used for contrast measurement. */
export const composites = {
  light: { "surface-sunken": "#e5edf0", "sand-sheer": "#f5f7fa" },
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
  { label: "ink على القوائم (surface-sunken)", theme: "light", text: colors.ink.light, background: composites.light["surface-sunken"], minimum: 4.5 },
  { label: "ink-muted على paper", theme: "light", text: colors["ink-muted"].light, background: colors.paper.light, minimum: 4.5 },
  { label: "ink-muted على surface", theme: "light", text: colors["ink-muted"].light, background: colors.surface.light, minimum: 4.5 },
  { label: "ink-muted على القوائم (surface-sunken)", theme: "light", text: colors["ink-muted"].light, background: composites.light["surface-sunken"], minimum: 4.5 },
  { label: "ink-muted على أرضية النزيل (sand-sheer)", theme: "light", text: colors["ink-muted"].light, background: composites.light["sand-sheer"], minimum: 4.5 },
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
  { label: "تعبئة الحقول على surface (ليل)", theme: "dark", text: colors["field-fill"].dark, background: colors.surface.dark, minimum: 3 },
  { label: "نص الحقول على تعبئتها (ليل)", theme: "dark", text: colors["field-ink"].dark, background: colors["field-fill"].dark, minimum: 4.5 },
  { label: "حلقة التركيز focus على paper (ليل)", theme: "dark", text: colors.focus.dark, background: colors.paper.dark, minimum: 3 },
];

/** Measured non-text boundary exception. This is not a passing AA boundary claim. */
export const knownContrastExceptions = [
  { label: "تعبئة الحقول على surface (ليل)", ratio: 1.54, minimum: 3, note: "The night fill is 1.54:1 against the shell. The subtle CSS field-border token is #274d57, a rounded 50% blend from field fill toward the V3 edge (1.047:1 against field fill). This owner-selected subtle edge does not claim SC 1.4.11 compliance." },
] as const;
