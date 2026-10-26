import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./supabase";
import { defaultPermissions, type Permissions } from "./permissionCatalog";
export { defaultPermissions, type Permissions };

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
  /** the person's permissions (the owner: everything) */
  permissions: Permissions;
  /** may the person do this operation of the matrix? */
  can: (code: string) => boolean;
  /** …without the cell's condition? */
  canFull: (code: string) => boolean;
  signIn: (email: string, password: string) => Promise<{ error: string | null }>;
  /** needsConfirmation: the account exists but the email must be confirmed (link sent) before the first sign-in */
  signUp: (email: string, password: string, fullName: string) => Promise<{ error: string | null; needsConfirmation?: boolean }>;
  signOut: () => Promise<void>;
}

/** Why the last session ended on this device, for the login page (decision 34): «revoked» = ended by the owner or a manager, or the account was deactivated. */
export const SIGNOUT_REASON_KEY = "zaaer.signout_reason";
export function takeSignOutReason(): string | null {
  try { const r = sessionStorage.getItem(SIGNOUT_REASON_KEY); if (r) sessionStorage.removeItem(SIGNOUT_REASON_KEY); return r; } catch { return null; }
}
/** The api layer announces a refusal; the auth provider re-checks the session (an ended session is refused everywhere at once). */
export const FORBIDDEN_EVENT = "zaaer:forbidden";

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<StaffProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [permissions, setPermissions] = useState<Permissions>(defaultPermissions(null));
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
        setPermissions(defaultPermissions(null));
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
    const prof = data as StaffProfile | null;
    const perms = prof ? await loadPermissions(prof.role) : defaultPermissions(null);
    if (token !== profileReqRef.current) return;
    profileUserRef.current = authUserId;
    setPermissions(perms);
    setProfile(prof);
    setLoading(false);
  }

  /** the matrix as the server applies it to this person; the approved defaults if the server cannot say */
  async function loadPermissions(role: string): Promise<Permissions> {
    try {
      const { data, error } = await supabase.rpc("fn_my_permissions", {});
      const d = data as { allowed?: string[]; full?: string[]; sees_money?: boolean } | null;
      if (error || !d || !Array.isArray(d.allowed)) return defaultPermissions(role);
      return { allowed: new Set(d.allowed), full: new Set(d.full ?? []), seesMoney: !!d.sees_money };
    } catch { return defaultPermissions(role); }
  }

  // decision 34: a session the owner or a manager ended (or an account deactivated) is refused by the server on its next
  // request; the browser notices on a refusal, when the tab comes back, and every minute, and signs out with a word for
  // the login page — it never keeps showing a screen the server would no longer serve.
  const hadProfileRef = useRef(false);
  const profileRoleRef = useRef<string | null>(null);
  useEffect(() => { hadProfileRef.current = !!profile; profileRoleRef.current = profile?.role ?? null; }, [profile]);
  useEffect(() => {
    let checking = false;
    const recheck = async () => {
      const uid = session?.user?.id;
      if (!uid || !hadProfileRef.current || checking) return;
      checking = true;
      try {
        const { data, error } = await supabase.from("staff_profiles").select("id").eq("auth_user_id", uid).maybeSingle();
        if (!error && !data && profileUserRef.current === uid) {
          try { sessionStorage.setItem(SIGNOUT_REASON_KEY, "revoked"); } catch { /* the notice is a convenience */ }
          await supabase.auth.signOut();
          setProfile(null);
        } else if (!error && data && profileUserRef.current === uid) {
          // the owner may have changed the matrix: the screens follow on the next check (the server already does)
          const role = profileRoleRef.current;
          if (role) {
            const next = await loadPermissions(role);
            setPermissions((cur) => (samePermissions(cur, next) ? cur : next));
          }
        }
      } finally { checking = false; }
    };
    const onVisible = () => { if (document.visibilityState === "visible") void recheck(); };
    window.addEventListener("focus", recheck); document.addEventListener("visibilitychange", onVisible); window.addEventListener(FORBIDDEN_EVENT, recheck);
    const timer = window.setInterval(recheck, 60_000);
    return () => { window.removeEventListener("focus", recheck); document.removeEventListener("visibilitychange", onVisible); window.removeEventListener(FORBIDDEN_EVENT, recheck); window.clearInterval(timer); };
  }, [session]);

  async function signIn(email: string, password: string) {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    return { error: error?.message ?? null };
  }

  async function signUp(email: string, password: string, fullName: string) {
    // the confirmation link brings the person back to this app's staff login (under its sub-path, if any);
    // the URL must be in the project's Auth redirect allow-list, otherwise Supabase falls back to the Site URL
    let emailRedirectTo: string | undefined;
    try { emailRedirectTo = new URL("staff/login", new URL(import.meta.env.BASE_URL, window.location.href)).toString(); } catch { /* Site URL */ }
    const { data, error } = await supabase.auth.signUp({ email, password, options: { emailRedirectTo } });
    if (error) return { error: error.message };
    if (data.session) {
      const { data: claim } = await supabase.rpc("fn_claim_staff_profile", { p_full_name: fullName });
      const c = claim as { ok?: boolean; error?: string } | null;
      if (!c?.ok) return { error: c?.error === "NO_INVITATION" ? "لا توجد دعوة لهذا البريد. اطلب من مالك المنشأة إضافتك من صفحة الموظفين." : "تعذّر ربط الحساب بملف موظف." };
      return { error: null };
    }
    // email confirmation is on: no session until the link is opened; the invitation is linked at the first sign-in
    return { error: null, needsConfirmation: true };
  }

  async function signOut() {
    await supabase.auth.signOut();
    setProfile(null);
    setPermissions(defaultPermissions(null));
  }

  return (
    <AuthContext.Provider value={{ session, profile, loading, permissions, can: (c) => permissions.allowed.has(c), canFull: (c) => permissions.full.has(c), signIn, signUp, signOut }}>
      {children}
    </AuthContext.Provider>
  );
}

function samePermissions(a: Permissions, b: Permissions) {
  return a.seesMoney === b.seesMoney && a.allowed.size === b.allowed.size && a.full.size === b.full.size
    && [...a.allowed].every((c) => b.allowed.has(c)) && [...a.full].every((c) => b.full.has(c));
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
