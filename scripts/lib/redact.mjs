/**
 * Masks what must never reach a test log, a report or a CI page (decision 56; non-negotiable: no personal data in
 * docs or logs): tokens and keys, e-mail addresses, Saudi mobile numbers, 10-digit identity numbers and long hex
 * secrets. Terminal colours are dropped, whitespace collapsed and the text shortened.
 */
export function redact(s, max = 300) {
  let t = String(s ?? "")
    .replace(/\u001b\[[0-9;]*[A-Za-z]/g, "")
    .replace(/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g, "‹jwt›")
    .replace(/\b(?:Bearer|bearer)\s+[A-Za-z0-9._~+/-]{12,}=*/g, "Bearer ‹token›")
    .replace(/\b(?:sk|pk|zb|sb|wa|key)_[A-Za-z0-9_-]{12,}/g, "‹key›")
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "‹email›")
    .replace(/(?<![\w-])(?:\+?966|00966|0)5\d{8}(?!\d)/g, "‹phone›")
    .replace(/(?<![\w-])[12]\d{9}(?!\d)/g, "‹id›")
    .replace(/\b[A-Fa-f0-9]{32,}\b/g, "‹hex›")
    .replace(/\s+/g, " ")
    .trim();
  if (t.length > max) t = t.slice(0, max - 1) + "…";
  return t;
}

