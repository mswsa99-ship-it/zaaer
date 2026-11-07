// Minimal Deno surface used by the edge functions so `tsc` can typecheck them without the Deno toolchain.
declare const Deno: {
  env: { get(k: string): string | undefined };
  serve(h: (req: Request) => Promise<Response> | Response): void;
  connectTls(o: { hostname: string; port: number }): Promise<{ read(b: Uint8Array): Promise<number | null>; write(b: Uint8Array): Promise<number>; close(): void }>;
};
declare module "npm:@supabase/supabase-js@2.45.4" { export * from "@supabase/supabase-js"; }
