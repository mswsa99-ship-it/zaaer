import { useEffect } from "react";
import { supabase } from "./supabase";
import { useBranchQuery, must } from "./useBranchQuery";
import { todayISO } from "./utils";

export interface ReservationCard {
  id: string;
  internal_ref: string;
  external_ref: string | null;
  status: string;
  check_in: string;
  check_out: string;
  adults: number;
  companions: number;
  payment_status: string;
  identity_status: string;
  government_registration: boolean;
  access_status: string;
  keybox_delivered: boolean;
  source?: { name: string };
  room?: { room_number: string };
  room_category?: { name_ar: string };
  primary_guest?: { full_name: string };
  branch?: { name_ar: string };
}

const NO_CARDS: ReservationCard[] = [];

// Operational columns only: money (total/paid/rent) is never read from the table — use fn_reservation_list /
// fn_reservation_finance, which the server gates by role (GAP05).
const SELECT = `
  id, internal_ref, external_ref, status, check_in, check_out, adults, companions,
  payment_status, identity_status, government_registration, access_status, keybox_delivered,
  source:booking_sources(name),
  room:rooms(room_number),
  room_category:room_categories(name_ar),
  branch:branches(name_ar)
`;

/**
 * Reservation cards of the ACTIVE branch (from BranchProvider), on the shared branch loader (decision 40, G24):
 * switching the branch clears the list and re-runs the query; a response for a branch that is no longer active (or
 * for an older reload) is dropped; no active branch → empty list (fail closed), never an unscoped query; a failed
 * load is reported as `error` (in Arabic), never as an empty list.
 */
export function useReservations(filter?: { status?: string[]; todayOnly?: boolean }) {
  const statusKey = filter?.status?.join(",") ?? "";
  const todayOnly = !!filter?.todayOnly;

  const q = useBranchQuery<ReservationCard[]>(async (branchId) => {
    let qq = supabase.from("reservations").select(SELECT).eq("branch_id", branchId);
    if (statusKey) qq = qq.in("status", statusKey.split(","));
    if (todayOnly) qq = qq.eq("check_in", todayISO());
    const list = must(await qq.order("created_at", { ascending: false })) as unknown as ReservationCard[];
    if (list.length === 0) return list;
    // Primary guests are loaded separately (reservation_guests is role-gated on the server: a role that may not
    // read them simply gets no rows, and the card shows "—").
    const guests = must(await supabase
      .from("reservation_guests")
      .select("reservation_id, full_name, is_primary")
      .in("reservation_id", list.map((r) => r.id))
      .eq("is_primary", true)) as { reservation_id: string; full_name: string }[];
    const guestMap = new Map(guests.map((g) => [g.reservation_id, g.full_name]));
    return list.map((r) => ({ ...r, primary_guest: { full_name: guestMap.get(r.id) ?? "—" } }));
  }, [statusKey, todayOnly], NO_CARDS);
  const reload = q.reload;

  // Realtime: any reservation change reloads the active branch's list.
  useEffect(() => {
    const channel = supabase
      .channel("reservations-realtime")
      .on("postgres_changes", { event: "*", schema: "public", table: "reservations" }, () => reload())
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [reload]);

  return { data: q.data, loading: q.loading, error: q.error, reload };
}
