import { useEffect, useRef } from "react";
import { useNavigate } from "react-router-dom";

/** 6.15 (U15): the keyboard shortcuts of the staff pages, listed on /staff/shortcuts from this one table. */
export const SHORTCUTS: { keys: string; label: string }[] = [
  { keys: "Ctrl + S", label: "حفظ النموذج المفتوح (النافذة المفتوحة أو نموذج الصفحة)" },
  { keys: "/", label: "الانتقال إلى حقل البحث في الصفحة" },
  { keys: "G ثم T", label: "الانتقال إلى «وصول اليوم»" },
  { keys: "G ثم R", label: "الانتقال إلى «الحجوزات»" },
  { keys: "G ثم N", label: "حجز جديد" },
  { keys: "?", label: "هذه الصفحة" },
];

export type ShortcutAction =
  | { type: "save" } | { type: "search" } | { type: "go"; path: string } | { type: "pending-g" } | null;

const GO: Record<string, string> = { t: "/staff/arrivals", r: "/staff/reservations", n: "/staff/reservations/new" };

/**
 * What a key press means. `typing` (a text field has the focus) turns off every single-key shortcut, so typing «/» or «g»
 * in a field never navigates; Ctrl+S works everywhere. `afterG`: «g» was pressed less than 1.5 s ago.
 */
export function shortcutAction(e: { key: string; ctrlKey?: boolean; metaKey?: boolean; altKey?: boolean }, typing: boolean, afterG: boolean): ShortcutAction {
  const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
  if ((e.ctrlKey || e.metaKey) && k === "s") return { type: "save" };
  if (e.ctrlKey || e.metaKey || e.altKey || typing) return null;
  if (afterG && GO[k]) return { type: "go", path: GO[k] };
  if (k === "g") return { type: "pending-g" };
  if (k === "/") return { type: "search" };
  if (k === "?") return { type: "go", path: "/staff/shortcuts" };
  return null;
}

const isTyping = (el: Element | null) => !!el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT" || (el as HTMLElement).isContentEditable);
const SEARCH = 'input[data-shortcut="search"], input[aria-label*="بحث"], input[placeholder*="بحث"], input[placeholder*="مرجع"], input[type="search"]';

function saveOpenForm() {
  const scope = document.querySelector('[role="dialog"]') ?? document.querySelector("main");
  const form = scope?.querySelector("form");
  if (!form) return false;
  const submit = form.querySelector<HTMLButtonElement>('button[type="submit"]');
  if (submit?.disabled) return true;           // the button says why it cannot save (6.8); the shortcut obeys the same rule
  form.requestSubmit(); return true;
}

export function useGlobalShortcuts() {
  const navigate = useNavigate();
  const gAt = useRef(0);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const a = shortcutAction(e, isTyping(document.activeElement), Date.now() - gAt.current < 1500);
      if (!a) return;
      if (a.type === "pending-g") { gAt.current = Date.now(); return; }
      gAt.current = 0;
      if (a.type === "save") { if (saveOpenForm()) e.preventDefault(); return; }
      if (a.type === "search") { const el = document.querySelector<HTMLInputElement>(SEARCH); if (el) { e.preventDefault(); el.focus(); } return; }
      if (document.querySelector('[role="dialog"]')) return;   // no navigation from under an open dialog
      e.preventDefault(); navigate(a.path);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [navigate]);
}
