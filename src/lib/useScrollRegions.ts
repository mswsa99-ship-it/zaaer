import { useEffect } from "react";

/** A table that scrolls sideways is a keyboard-reachable, named region (WCAG 2.1.1 / 1.3.1): Tab reaches it and the arrow keys scroll it.
 *  Only containers that really overflow are marked, and only plain scroll areas (not the tab strips, which already have their own roles). */
const SEL = "main .overflow-x-auto:not([role='tablist']):not(nav):not([data-no-scroll-region])";

export function useScrollRegions(routeKey: string) {
  useEffect(() => {
    const mark = () => {
      document.querySelectorAll<HTMLElement>(SEL).forEach((el) => {
        const over = el.scrollWidth > el.clientWidth + 2;
        if (over) {
          if (!el.hasAttribute("tabindex")) { el.setAttribute("tabindex", "0"); el.dataset.scrollRegion = "1"; }
          if (!el.hasAttribute("role")) el.setAttribute("role", "region");
          if (!el.hasAttribute("aria-label") && !el.hasAttribute("aria-labelledby")) el.setAttribute("aria-label", "جدول قابل للتمرير أفقيًا");
        } else if (el.dataset.scrollRegion === "1") {
          el.removeAttribute("tabindex"); el.removeAttribute("role"); el.removeAttribute("aria-label"); delete el.dataset.scrollRegion;
        }
      });
    };
    mark();
    const mo = new MutationObserver(() => mark());
    const main = document.getElementById("main");
    if (main) mo.observe(main, { childList: true, subtree: true });
    window.addEventListener("resize", mark);
    return () => { mo.disconnect(); window.removeEventListener("resize", mark); };
  }, [routeKey]);
}
