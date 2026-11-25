/**
 * Plan 3.2 — the style rule that rejects directly written colors (قاعدة فحص أسلوب ترفض الألوان المباشرة).
 * A color must come from the single token file, so a literal in a component is a violation. Detection is
 * line-based and purely textual: hex values (#rgb, #rrggbb, #rrggbbaa) and CSS color functions
 * (rgb/rgba/hsl/hsla), including inside Tailwind arbitrary values such as bg-[#173e4d].
 * A line carrying the marker «token-ok» is exempt (documented exception, e.g. a third-party embed).
 * Named Tailwind classes (text-ink-500) and token references are not literals and are never flagged.
 */

const HEX = /#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})(?![0-9a-fA-F])/g;
const CSS_FUNCTION = /\b(?:rgba?|hsla?)\([^)]*\)/g;
export const EXEMPTION = "token-ok";

/**
 * Finds hardcoded colors in one source text.
 * @param {string} source
 * @param {string} [file] path used in the report
 * @returns {Array<{file:string,line:number,column:number,match:string,kind:"hex"|"function",context:string}>}
 */
export function findHardcodedColors(source, file = "<text>") {
  const out = [];
  const lines = String(source).split("\n");
  for (let i = 0; i < lines.length; i++) {
    const text = lines[i];
    if (text.includes(EXEMPTION)) continue;
    for (const [re, kind] of [[HEX, "hex"], [CSS_FUNCTION, "function"]]) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(text))) {
        // a «#» inside a URL fragment or an import path is not a color: require a non-word character or start before it
        const before = m.index === 0 ? "" : text[m.index - 1];
        if (kind === "hex" && /[\p{L}\p{N}_]/u.test(before)) continue;
        out.push({ file, line: i + 1, column: m.index + 1, match: m[0], kind, context: text.trim() });
      }
    }
  }
  return out;
}

/** True when the source is free of hardcoded colors. */
export function isClean(source) {
  return findHardcodedColors(source).length === 0;
}
