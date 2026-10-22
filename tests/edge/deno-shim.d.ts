// Minimal Deno surface used by the edge functions so `tsc` can typecheck them without the Deno toolchain.
declare const Deno: {
  env: { get(k: string): string | undefined };
  serve(h: (req: Request) => Promise<Response> | Response): void;
};
declare module "npm:@supabase/supabase-js@2.45.4" { export * from "@supabase/supabase-js"; }
