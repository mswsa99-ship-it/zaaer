/**
 * A11Y-03 / IX-10: a drawer or panel that takes focus when it opens, keeps Tab inside it, closes on Escape and gives
 * focus back to the control that opened it.
 */
import { useEffect, useRef, type RefObject } from "react";

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function useFocusTrap(open: boolean, box: RefObject<HTMLElement>, onClose: () => void) {
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    if (!open) return;
    const opener = document.activeElement as HTMLElement | null;
    const list = () => Array.from(box.current?.querySelectorAll<HTMLElement>(FOCUSABLE) ?? []).filter((el) => el.offsetParent !== null);
    (list()[0] ?? box.current)?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") { close.current(); return; }
      if (e.key !== "Tab") return;
      const items = list(); if (items.length === 0) return;
      const first = items[0], last = items[items.length - 1];
      const inside = box.current?.contains(document.activeElement);
      if (e.shiftKey && (document.activeElement === first || !inside)) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && (document.activeElement === last || !inside)) { e.preventDefault(); first.focus(); }
    };
    document.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("keydown", onKey); if (opener && document.contains(opener)) opener.focus(); };
  }, [open, box]);
}

/**
 * A11Y-11 / A11Y-14: after moving to another page, focus goes to the page's content (not left on <body>), and
 * «تخطَّ إلى المحتوى» jumps there from the top.
 */
export function useMainFocusOnRoute(pathname: string) {
  const first = useRef(true);
  useEffect(() => {
    if (first.current) { first.current = false; return; }
    const main = document.getElementById("main");
    if (main && !main.contains(document.activeElement)) main.focus({ preventScroll: true });
  }, [pathname]);
}

export function focusMain(e: { preventDefault: () => void }) {
  e.preventDefault();
  const main = document.getElementById("main");
  main?.focus();
  main?.scrollIntoView({ block: "start" });
}

/**
 * IX-02: a new page opens at its top; Back and Forward return a page to where it was left.
 */
const scrollByKey = new Map<string, number>();
export function useScrollOnRoute(key: string, pathname: string, navType: "POP" | "PUSH" | "REPLACE") {
  const prev = useRef<string | null>(null);
  useEffect(() => {
    const leaving = prev.current;
    prev.current = key;
    const save = () => { scrollByKey.set(key, window.scrollY); };
    window.addEventListener("scroll", save, { passive: true });
    if (leaving !== null) {
      if (navType === "POP" && scrollByKey.has(key)) {
        const y = scrollByKey.get(key)!;
        requestAnimationFrame(() => requestAnimationFrame(() => window.scrollTo(0, y)));   // after the page has drawn
      } else window.scrollTo(0, 0);
    }
    return () => window.removeEventListener("scroll", save);
  }, [key, pathname, navType]);
}
