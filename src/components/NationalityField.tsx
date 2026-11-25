import { useState } from "react";

/**
 * Nationality: a drop-down of the ten nationalities most common among the guests plus «أخرى», which opens one manual field
 * (user rule 25 Nov 12:32: no free typing by default). The stored value is the Arabic name, as before.
 * The ten are a practical default list, not a legal one, and are easy to change here.
 */
export const COMMON_NATIONALITIES = ["سعودي", "مصري", "يمني", "سوداني", "سوري", "أردني", "باكستاني", "هندي", "بنغلاديشي", "فلبيني"] as const;
const OTHER = "__other__";
const clean = (s: string) => s.replace(/[^\p{L}\s'’.-]/gu, "").replace(/\s+/g, " ").trimStart();

export function NationalityField({ value, onChange, className, otherLabel = "أخرى", manualLabel = "اكتب الجنسية", ariaLabel = "الجنسية" }: { value: string; onChange: (v: string) => void; className?: string; otherLabel?: string; manualLabel?: string; ariaLabel?: string }) {
  const known = (COMMON_NATIONALITIES as readonly string[]).includes(value.trim());
  const [other, setOther] = useState(!known && value.trim() !== "");
  const selected = known ? value.trim() : other || value.trim() !== "" ? OTHER : "";
  return (
    <div className={className}>
      <select className="input" value={selected} aria-label={ariaLabel} data-testid="nationality-select"
        onChange={(e) => { const v = e.target.value; if (v === OTHER) { setOther(true); onChange(""); } else { setOther(false); onChange(v); } }}>
        <option value="" disabled>—</option>
        {COMMON_NATIONALITIES.map((n) => <option key={n} value={n}>{n}</option>)}
        <option value={OTHER}>{otherLabel}</option>
      </select>
      {selected === OTHER && <input className="input mt-2" value={value} maxLength={40} placeholder={manualLabel} aria-label={manualLabel} data-testid="nationality-other" onChange={(e) => onChange(clean(e.target.value))} />}
    </div>
  );
}
