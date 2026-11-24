/** 6.8 (U9): the visible, announced reason a control is disabled. Render it beside the control and point aria-describedby at its id. */
export function DisabledReason({ id, show, text }: { id: string; show: boolean; text: string }) {
  if (!show) return null;
  return <span id={id} className="text-xs text-rai-ink-muted" data-testid="disabled-reason">{text}</span>;
}
