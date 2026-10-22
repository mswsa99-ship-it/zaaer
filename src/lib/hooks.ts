import { useEffect, useState, useCallback, useRef } from "react";
import { supabase } from "./supabase";
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

// Operational columns only: money (total/paid/rent) is never read from the table — use fn_reservation_list /
// fn_reservation_finance, which the server gates by role (A05).
const SELECT = `
  id, internal_ref, external_ref, status, check_in, check_out, adults, companions,
  payment_status, identity_status, government_registration, access_status, keybox_delivered,
  source:booking_sources(name),
  room:rooms(room_number),
  room_category:room_categories(name_ar),
  branch:branches(name_ar)
`;

/**
 * Reservation cards of the ACTIVE branch (from BranchProvider). Switching the branch re-runs the query; a response
 * that arrives for a branch that is no longer active (or for an older reload) is ignored. No active branch → empty
 * list (fail closed), never an unscoped query.
 */
export function useReservations(filter?: { status?: string[]; todayOnly?: boolean }) {
  const { branchId, loading: branchLoading } = useBranch();
  const [data, setData] = useState<ReservationCard[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const reqRef = useRef(0);

  const statusKey = filter?.status?.join(",") ?? "";
  const todayOnly = !!filter?.todayOnly;

  const load = useCallback(async () => {
    const token = ++reqRef.current;
    if (branchLoading) return;
    if (!branchId) { setData([]); setError(null); setLoading(false); return; }
    setLoading(true);
    let q = supabase.from("reservations").select(SELECT).eq("branch_id", branchId);
    if (statusKey) q = q.in("status", statusKey.split(","));
    if (todayOnly) q = q.eq("check_in", new Date().toISOString().slice(0, 10));
    q = q.order("created_at", { ascending: false });
    const { data: rows, error: e } = await q;
    if (token !== reqRef.current) return; // branch changed or a newer load started meanwhile
    if (e) { setError(e.message); setLoading(false); return; }

    let list = (rows as unknown as ReservationCard[]) ?? [];
    if (list.length > 0) {
      // Primary guests are loaded separately (reservation_guests is role-gated on the server).
      const { data: guests } = await supabase
        .from("reservation_guests")
        .select("reservation_id, full_name, is_primary")
        .in("reservation_id", list.map((r) => r.id))
        .eq("is_primary", true);
      if (token !== reqRef.current) return;
      const guestMap = new Map((guests ?? []).map((g: { reservation_id: string; full_name: string }) => [g.reservation_id, g.full_name]));
      list = list.map((r) => ({ ...r, primary_guest: { full_name: guestMap.get(r.id) ?? "—" } }));
    }
    setError(null);
    setData(list);
    setLoading(false);
  }, [branchId, branchLoading, statusKey, todayOnly]);

  useEffect(() => {
    load();
  }, [load]);

  // Realtime
  useEffect(() => {
    const channel = supabase
      .channel("reservations-realtime")
      .on("postgres_changes", { event: "*", schema: "public", table: "reservations" }, () => load())
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [load]);

  // Drop whatever is still in flight when the consumer unmounts.
  useEffect(() => () => { reqRef.current++; }, []);

  return { data, loading, error, reload: load };
}
