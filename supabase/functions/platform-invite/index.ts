/** Retired: hotel owners self-register; this endpoint must never send mail. */
const headers = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization,apikey,content-type,x-client-info", "Content-Type": "application/json" };
Deno.serve((req) => req.method === "OPTIONS" ? new Response("ok", { headers }) : new Response(JSON.stringify({ ok: false, error: "owner_self_signup_required" }), { status: 410, headers }));
