import { useEffect, useId } from "react";
import { supabase } from "./supabase";
import { useBranchQuery, must } from "./useBranchQuery";
import { useAuth } from "./auth";
import { useBranch } from "./branch";

export interface ReservationCard {
  id: string;
  internal_ref: string;
  external_ref: string | null;
  status: string;
  check_in: string;
  check_out: string;
  adults: number;
  companions: number;
  payment_status: string | null;
  identity_status: string;
  government_registration: boolean;
  /** 0033: Shomoos accepted the registration (the arrival's last fixed condition) */
  shomoos_accepted_at?: string | null;
  access_status: string;
  keybox_delivered: boolean;
  /** B8–B10: when the guest arrived, and the row's last change (the windows of «تمت معالجته») */
  actual_check_in?: string | null;
  updated_at?: string | null;
  source?: { name: string };
  room?: { room_number: string };
  room_category?: { name_ar: string };
  primary_guest?: { full_name: string };
  branch?: { name_ar: string };
}

const NO_CARDS: ReservationCard[] = [];


/**
 * Reservation cards of the ACTIVE branch (from BranchProvider), on the shared branch loader (decision 40, G24):
 * switching the branch clears the list and re-runs the query; a response for a branch that is no longer active (or
 * for an older reload) is dropped; no active branch → empty list (fail closed), never an unscoped query; a failed
 * load is reported as `error` (in Arabic), never as an empty list.
 */
export function useReservations(filter?: { status?: string[]; todayOnly?: boolean }) {
  const statusKey = filter?.status?.join(",") ?? "";
  const todayOnly = !!filter?.todayOnly;
  // 0052 (PERM-07): the payment status is money — a role the matrix does not let see money never gets it on a card
  const money = useAuth().permissions.seesMoney;
  // «جميع الفروع» (owner): a card says which branch it belongs to, since unit numbers repeat across branches
  const { allBranches, branches } = useBranch();

  const q = useBranchQuery<ReservationCard[]>(async (branchId) => {
    const { data: cards, error: cardsErr } = await supabase.rpc("fn_reservation_cards", { p_branch: branchId, p_status: statusKey ? statusKey.split(",") : null, p_today_only: todayOnly });
    if (cardsErr) throw cardsErr;
    const branchName = allBranches ? branches.find((b) => b.id === branchId)?.name_ar : undefined;
    const list = ((cards ?? []) as unknown as ReservationCard[]).map((r) => branchName ? { ...r, branch: { name_ar: branchName } } : r);
    if (list.length === 0) return list;
    // Primary guests are loaded separately (reservation_guests is role-gated on the server: a role that may not
    // read them simply gets no rows, and the card shows "—").
    const guests = must(await supabase
      .from("reservation_guests")
      .select("reservation_id, full_name, is_primary")
      .in("reservation_id", list.map((r) => r.id))
      .eq("is_primary", true)) as { reservation_id: string; full_name: string }[];
    const guestMap = new Map(guests.map((g) => [g.reservation_id, g.full_name]));
    return list.map((r) => ({ ...r, payment_status: money ? r.payment_status : null, primary_guest: { full_name: guestMap.get(r.id) ?? "—" } }));
  }, [statusKey, todayOnly, money, allBranches, branches], NO_CARDS, { merge: (parts) => parts.flat() });   // «جميع الفروع» (owner): every branch's cards in one list
  const reload = q.reload;

  // Realtime: any reservation change reloads the active branch's list. Each use of this hook has its own channel:
  // a page that lists reservations twice (the operations board: today's arrivals and all) must not reuse one channel
  // name — the realtime client refuses callbacks on a channel already subscribed and the page goes blank.
  const channelName = useId();
  useEffect(() => {
    const channel = supabase
      .channel(`reservations-realtime-${channelName}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "reservations" }, () => reload())
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [reload, channelName]);

  return { data: q.data, loading: q.loading, error: q.error, reload };
}
