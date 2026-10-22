/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string;
  readonly VITE_SUPABASE_ANON_KEY: string;
  /** "staging" | "production" — set by the deploy workflow; anything but production shows the environment ribbon */
  readonly VITE_APP_ENV?: string;
  readonly VITE_DEMO?: string;
  readonly VITE_DEFAULT_BRANCH_ID?: string;
  readonly VITE_KIOSK_IDLE_MS?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
