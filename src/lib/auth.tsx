import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./supabase";

export interface StaffProfile {
  id: string;
  auth_user_id: string | null;
  organization_id: string;
  full_name: string;
  email: string;
  phone: string | null;
  role: "owner" | "manager" | "supervisor" | "finance" | "housekeeping" | "guest";
  is_active: boolean;
}

interface AuthContextValue {
  session: Session | null;
  profile: StaffProfile | null;
  loading: boolean;
  signIn: (email: string, password: string) => Promise<{ error: string | null }>;
  signUp: (email: string, password: string, fullName: string) => Promise<{ error: string | null }>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<StaffProfile | null>(null);
  const [loading, setLoading] = useState(true);
  /** auth user id whose profile lookup has completed (found or not) — see onAuthStateChange. */
  const profileUserRef = useRef<string | null>(null);
  const profileReqRef = useRef(0);

  useEffect(() => {
    let mounted = true;
    supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return;
      setSession(data.session);
      if (data.session) {
        loadProfile(data.session.user.id);
      } else {
        setLoading(false);
      }
    });

    const { data: sub } = supabase.auth.onAuthStateChange((_event, sess) => {
      setSession(sess);
      if (sess) {
        // A different (or first) user: hold the guards until the profile is known, so a protected page is never
        // rendered for a session whose role is still unknown. Token refreshes of the same user do not re-gate.
        if (profileUserRef.current !== sess.user.id) setLoading(true);
        loadProfile(sess.user.id);
      } else {
        profileReqRef.current++; // drop any in-flight lookup
        profileUserRef.current = null;
        setProfile(null);
        setLoading(false);
      }
    });

    return () => {
      mounted = false;
      sub.subscription.unsubscribe();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function loadProfile(authUserId: string) {
    const token = ++profileReqRef.current;
    let { data } = await supabase
      .from("staff_profiles")
      .select("id, auth_user_id, organization_id, full_name, email, phone, role, is_active")
      .eq("auth_user_id", authUserId)
      .maybeSingle();
    if (!data) {
      // Link a pending invitation (by email) or, in demo mode with no staff yet, bootstrap the first owner.
      // Everything is decided server-side (fn_claim_staff_profile); the browser cannot pick its own role.
      await supabase.rpc("fn_claim_staff_profile", { p_full_name: null });
      ({ data } = await supabase
        .from("staff_profiles")
        .select("id, auth_user_id, organization_id, full_name, email, phone, role, is_active")
        .eq("auth_user_id", authUserId)
        .maybeSingle());
    }
    if (token !== profileReqRef.current) return; // a later sign-in/out superseded this lookup
    profileUserRef.current = authUserId;
    setProfile(data as StaffProfile | null);
    setLoading(false);
  }

  async function signIn(email: string, password: string) {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    return { error: error?.message ?? null };
  }

  async function signUp(email: string, password: string, fullName: string) {
    const { data, error } = await supabase.auth.signUp({ email, password });
    if (error) return { error: error.message };
    if (data.session) {
      const { data: claim } = await supabase.rpc("fn_claim_staff_profile", { p_full_name: fullName });
      const c = claim as { ok?: boolean; error?: string } | null;
      if (!c?.ok) return { error: c?.error === "NO_INVITATION" ? "لا توجد دعوة لهذا البريد. اطلب من مالك المنشأة إضافتك من صفحة الموظفين." : "تعذّر ربط الحساب بملف موظف." };
    }
    return { error: null };
  }

  async function signOut() {
    await supabase.auth.signOut();
    setProfile(null);
  }

  return (
    <AuthContext.Provider value={{ session, profile, loading, signIn, signUp, signOut }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
