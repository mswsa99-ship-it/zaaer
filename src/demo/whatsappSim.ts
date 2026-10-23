/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * The demo's WhatsApp simulator plays the program on the reception computer. What the guest types goes through the
 * very same server code as the real thing — supabase/functions/_shared/wa_bridge.ts → wa_flow.ts → ai-reception —
 * against the demo store, and the answers come back as the plain text WhatsApp Web types for the guest.
 * Staff replies from the inbox are picked up here the way the program picks them up (poll + ack).
 */
import { handleBridge } from "../../supabase/functions/_shared/wa_bridge";
import type { WaEnv } from "../../supabase/functions/_shared/wa_db";
import { createDemoServiceClient, demoBridgeKey, demoFunctionsFetch } from "./client";

const db = createDemoServiceClient();
const env = (): WaEnv => ({
  // HashRouter: the secure pages open inside the demo (…/#/booking/status/<token>)
  appBaseUrl: window.location.href.split("#")[0] + "#",
  supabaseUrl: "https://demo.invalid", serviceKey: "demo", fetcher: demoFunctionsFetch,
});
const chatOf = (phone: string) => `${phone}@c.us`;
let seq = 0;

export interface SimGuest { phone: string; label: string; bookings: number }
export interface SimTurn { replies: string[]; silent?: string; error?: string }

/** demo guests to write as (first name and number of bookings only), and one number without bookings */
export async function simGuests(): Promise<SimGuest[]> {
  const { data: guests } = await db.from("reservation_guests").select("reservation_id, full_name, phone, is_primary").eq("is_primary", true);
  const { data: res } = await db.from("reservations").select("id, status");
  const live = new Set(((res as any[]) ?? []).filter((r) => ["confirmed", "checked_in", "pending_verification"].includes(r.status)).map((r) => r.id));
  const byPhone = new Map<string, { name: string; n: number }>();
  for (const g of (guests as any[]) ?? []) {
    const ph = normalize(g.phone);
    if (!ph || !live.has(g.reservation_id)) continue;
    const cur = byPhone.get(ph) ?? { name: String(g.full_name ?? "").split(" ")[0], n: 0 };
    cur.n += 1;
    byPhone.set(ph, cur);
  }
  const list = [...byPhone.entries()].sort((a, b) => b[1].n - a[1].n).slice(0, 4)
    .map(([phone, x]) => ({ phone, bookings: x.n, label: `${x.name} — ${x.n === 1 ? "حجز واحد" : x.n === 2 ? "حجزان" : `${x.n} حجوزات`}` }));
  return [...list, { phone: "966509990000", bookings: 0, label: "رقم جديد — بلا حجوزات" }];
}

function normalize(p: unknown): string | null {
  const d = String(p ?? "").replace(/\D/g, "");
  if (/^05\d{8}$/.test(d)) return "966" + d.slice(1);
  if (/^9665\d{8}$/.test(d)) return d;
  return null;
}

async function call(branchId: string, body: Record<string, unknown>) {
  const key = demoBridgeKey(branchId);
  if (!key) return { status: 409, body: { error: "not_linked" } as Record<string, unknown> };
  return handleBridge(db, key, body, env(), { sleep: async () => {} });
}

/** the guest sends a message → what the reception computer would type back */
export async function simSend(branchId: string, phone: string, text: string): Promise<SimTurn> {
  const r = await call(branchId, { action: "message", id: `sim-${Date.now()}-${++seq}`, chat: chatOf(phone), type: "text", text, ts: Date.now() });
  if (r.status !== 200) return { replies: [], error: String(r.body.error ?? "error") };
  return { replies: (r.body.replies as string[]) ?? [], silent: r.body.silent as string | undefined };
}

/** a receptionist answers from WhatsApp itself (phone or the WhatsApp Web window) → the assistant steps back there */
export async function simHumanReply(branchId: string, phone: string, text: string): Promise<{ until?: string; error?: string }> {
  const r = await call(branchId, { action: "human", id: `sim-h-${Date.now()}-${++seq}`, chat: chatOf(phone), text });
  return r.status === 200 ? { until: r.body.human_active_until as string } : { error: String(r.body.error ?? "error") };
}

export interface SimStaffItem { id: string; chat_id: string; text: string }
/**
 * heartbeat + staff replies from the inbox waiting to be typed. Like the program, each one is confirmed only after it
 * was shown (`deliver` returns false when the simulator is gone: the reply is then reported as not sent).
 */
export async function simPollStaff(branchId: string, linkedPhone: string | null, deliver: (it: SimStaffItem) => boolean = () => true): Promise<SimStaffItem[]> {
  const r = await call(branchId, { action: "poll", status: "connected", phone: linkedPhone, name: "محاكاة العرض", version: "demo", wait: 0 });
  if (r.status !== 200) return [];
  const items = (r.body.outbox as SimStaffItem[]) ?? [];
  const shown: SimStaffItem[] = [];
  for (const it of items) {
    const ok = deliver(it);
    if (ok) shown.push(it);
    await call(branchId, ok ? { action: "ack", id: it.id, ok: true, wa_id: "sim-" + it.id } : { action: "ack", id: it.id, ok: false, error: "simulator_closed" });
  }
  return shown;
}

export const simChatOf = chatOf;
