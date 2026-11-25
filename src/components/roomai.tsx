/**
 * Plan 3.3 — المكوّنات الأساسية: typed React wrappers over the approved rai- classes (src/roomai.css), so the
 * screens of phase 6 are built from these and never re-derive the styles. Every value is a token (3.2); the
 * gallery at /design-gallery (demo build) shows each one with its states.
 */
import { cloneElement, isValidElement, useId, type ButtonHTMLAttributes, type ReactNode } from "react";
import { Check, Calendar, User, Droplets, Ban, Sparkles, Lock, CheckCircle2, AlertTriangle, XCircle, Info } from "lucide-react";
import { POWERED_BY } from "../lib/designTokens";

type ButtonVariant = "default" | "primary" | "quiet" | "danger" | "ai";

/** The approved button: one primary (night) per area; ai is only for asking the assistant. */
export function RaiButton({ variant = "default", touch, className = "", ...rest }: { variant?: ButtonVariant; touch?: boolean } & ButtonHTMLAttributes<HTMLButtonElement>) {
  const cls = ["rai-btn", variant !== "default" && `rai-btn-${variant}`, touch && "rai-btn-touch", className].filter(Boolean).join(" ");
  return <button type="button" className={cls} {...rest} />;
}

/** A label above, the field, and one line under it: a hint, or the error that replaces it. */
export function RaiField({ label, hint, error, locked, ltr, children }: { label: string; hint?: string; error?: string | null; locked?: boolean; ltr?: boolean; children: ReactNode }) {
  const generatedId = useId();
  const input = isValidElement<React.InputHTMLAttributes<HTMLInputElement>>(children) ? children : null;
  const id = input?.props.id ?? generatedId;
  const noteId = `${id}-note`;
  const content = input ? cloneElement(input, {
    id,
    "aria-describedby": [input.props["aria-describedby"], (error || hint) && noteId].filter(Boolean).join(" ") || undefined,
    "aria-invalid": error ? true : input.props["aria-invalid"],
  }) : children;
  return (
    <div className={`rai-field${error ? " is-error" : ""}`}>
      <label className="rai-label" htmlFor={id}>
        {label}
        {locked && <span className="rai-lock"><Lock aria-hidden /> يظهر لبعض الأدوار فقط</span>}
      </label>
      <div dir={ltr ? "ltr" : undefined}>{content}</div>
      {(error || hint) && <span id={noteId} className="rai-hint" role={error ? "alert" : undefined}>{error ?? hint}</span>}
    </div>
  );
}

export function RaiInput(props: React.InputHTMLAttributes<HTMLInputElement>) {
  return <input className="rai-input" {...props} />;
}

/** The five states of a unit: colour, icon and word together — colour never carries the meaning alone. */
export const ROOM_STATES = {
  available: { cls: "rai-pill-available", word: "متاحة", Icon: Check },
  reserved: { cls: "rai-pill-reserved", word: "محجوزة", Icon: Calendar },
  occupied: { cls: "rai-pill-occupied", word: "مشغولة", Icon: User },
  cleaning: { cls: "rai-pill-cleaning", word: "قيد التنظيف", Icon: Droplets },
  out: { cls: "rai-pill-out", word: "خارج الخدمة", Icon: Ban },
} as const;
export type RoomState = keyof typeof ROOM_STATES;

export function RoomStatusPill({ state, testId }: { state: RoomState; testId?: string }) {
  const { cls, word, Icon } = ROOM_STATES[state];
  return <span className={`rai-pill ${cls}`} data-testid={testId}><Icon aria-hidden />{word}</span>;
}

/** One number the shift starts from, in the display face, with its label above and one line of context under it. */
export function StatTile({ label, value, note, warning, onOpen }: { label: string; value: ReactNode; note?: string; warning?: boolean; onOpen?: () => void }) {
  const inner = (
    <>
      <span className="rai-stat-label">{label}</span>
      <span className="rai-stat-value rai-num">{value}</span>
      {note && <span className="rai-stat-note">{note}</span>}
    </>
  );
  // Tiles are links to the list behind the number
  return onOpen
    ? <button type="button" className={`rai-stat${warning ? " is-warning" : ""}`} onClick={onOpen}>{inner}</button>
    : <div className={`rai-stat${warning ? " is-warning" : ""}`}>{inner}</div>;
}

/** Everything the assistant proposes appears in this card and nowhere else. It proposes; a person decides. */
export function AISuggestion({ body, source, onAct, actLabel, onIgnore }: { body: string; source: string; onAct?: () => void; actLabel?: string; onIgnore?: () => void }) {
  return (
    <div className="rai-ai">
      <div className="rai-ai-head"><Sparkles aria-hidden /> اقتراح من المساعد</div>
      <p className="rai-ai-body">{body}</p>
      <div className="rai-ai-actions">
        {onAct && <RaiButton variant="primary" onClick={onAct}>{actLabel ?? "نفّذ"}</RaiButton>}
        {onIgnore && <RaiButton variant="quiet" onClick={onIgnore}>تجاهل</RaiButton>}
      </div>
      <div className="rai-ai-foot">المصدر: {source}</div>
    </div>
  );
}

type NoticeKind = "success" | "warning" | "danger" | "info";

/** What happened, why, and what to do next, in the colour of its outcome. Errors are role="alert". */
export function Notice({ kind, children, testId }: { kind: NoticeKind; children: ReactNode; testId?: string }) {
  const Icon = { success: CheckCircle2, warning: AlertTriangle, danger: XCircle, info: Info }[kind];
  return (
    <div className={`rai-notice rai-notice-${kind}`} role={kind === "danger" ? "alert" : "status"} data-testid={testId}>
      <Icon aria-hidden="true" />
      <span>{children}</span>
    </div>
  );
}

/** The only RoomAI appearance on guest pages: the footer line with the 16px mark (GuestBrand). */
export function GuestFooter() {
  return (
    <div className="rai-guest-foot">
      <img src="roomai/roomai-mark.svg" alt="" width={16} height={16} />
      <span>{POWERED_BY}</span>
    </div>
  );
}
