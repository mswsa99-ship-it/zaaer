import { createClient, type SupabaseClient } from "@supabase/supabase-js";

/** Demo build (VITE_DEMO=1): an in-browser backend replaces Supabase so the whole UI can be explored without a server. */
export const isDemo = import.meta.env.VITE_DEMO === "1";

function realClient(): SupabaseClient {
  const url = import.meta.env.VITE_SUPABASE_URL as string;
  const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
  if (!url || !anonKey) throw new Error("Missing Supabase env vars. Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in .env");
  return createClient(url, anonKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
}

async function demoClient(): Promise<SupabaseClient> {
  const m = await import("../demo/client");
  return m.createDemoClient() as unknown as SupabaseClient;
}

// The demo module is only bundled when the flag is on (dynamic import), but the client must be
// synchronous for the pages: in demo builds Vite inlines the chunk, and we resolve it eagerly.
export const supabase: SupabaseClient = isDemo ? (await demoClient()) : realClient();
