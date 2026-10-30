/**
 * U1 note 13 (WCAG 4.1.2): many forms write a visible «label» line and its control as siblings, without `htmlFor`.
 * This links each such label to the control after it (or inside the same wrapper) for screen readers, once, as the
 * page renders — a control that already has a name (aria-label, aria-labelledby or a real <label for>) is left as is.
 */
let n = 0;
const CONTROL = "input:not([type=hidden]):not([type=checkbox]):not([type=radio]), select, textarea";

function named(el: Element): boolean {
  return !!(el.getAttribute("aria-label") || el.getAttribute("aria-labelledby") || (el as HTMLInputElement).labels?.length);
}

export function linkLabels(root: ParentNode = document): void {
  root.querySelectorAll<HTMLLabelElement>("label.label:not([for])").forEach((label) => {
    if (label.querySelector(CONTROL)) return;   // a label that wraps its control names it already
    let ctl: Element | null = null;
    for (let sib = label.nextElementSibling; sib && !ctl; sib = sib.nextElementSibling) {
      ctl = sib.matches(CONTROL) ? sib : sib.querySelector(CONTROL);
      if (sib.matches("label.label")) break;
    }
    if (!ctl || named(ctl)) return;
    if (!label.id) label.id = `lbl-auto-${++n}`;
    ctl.setAttribute("aria-labelledby", label.id);
  });
}

export function startLabelLinker(): void {
  if (typeof MutationObserver === "undefined") return;
  let queued = false;
  const run = () => { queued = false; linkLabels(); };
  new MutationObserver(() => { if (!queued) { queued = true; requestAnimationFrame(run); } }).observe(document.body, { childList: true, subtree: true });
  run();
}
