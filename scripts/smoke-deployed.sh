#!/usr/bin/env bash
# Post-deploy smoke for a hosted environment (staging / production). Read-only: it creates at most one
# guest conversation ("مرحبا") and never touches reservations, money or staff data.
# Needs: APP_BASE_URL, VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY
# STATIC_HOST=github-pages: the host has no rewrites and no custom headers (the staging site). Deep links are then
# answered by 404.html — which is the app itself — so status 404 with the app shell counts as served, and the
# security-header check is reported as skipped instead of failed. Production (Netlify) keeps both checks strict.
set -uo pipefail
fail=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fail=1; }
base="${APP_BASE_URL%/}"; api="${VITE_SUPABASE_URL%/}"; key="$VITE_SUPABASE_ANON_KEY"

static="${STATIC_HOST:-}"

# 1. the web app is served, and deep links fall back to the SPA
for path in / /reception /staff/login /admin/knowledge; do
  code=$(curl -s -o /tmp/smoke.html -w "%{http_code}" "$base$path")
  served=0
  [[ "$code" == "200" ]] && served=1
  [[ "$static" == "github-pages" && "$path" != "/" && "$code" == "404" ]] && served=1
  if [[ $served == 1 ]] && grep -q 'id="root"' /tmp/smoke.html; then ok "web $path → $code (app shell)"; else bad "web $path → $code"; fi
done

# 2. security headers are present
if [[ "$static" == "github-pages" ]]; then
  echo "SKIP security headers — GitHub Pages cannot set response headers (staging only; production serves them from netlify.toml)"
else
  hdr=$(curl -sI "$base/")
  grep -qi "x-frame-options: DENY" <<<"$hdr" && ok "header X-Frame-Options" || bad "header X-Frame-Options missing"
  grep -qi "x-content-type-options: nosniff" <<<"$hdr" && ok "header X-Content-Type-Options" || bad "header X-Content-Type-Options missing"
fi

# 3. anonymous clients cannot read operational tables (RLS / grants) — must be refused or empty
for t in reservations financial_vouchers knowledge_entries staff_profiles; do
  body=$(curl -s -w "\n%{http_code}" "$api/rest/v1/$t?select=id&limit=1" -H "apikey: $key" -H "Authorization: Bearer $key")
  code=$(tail -n1 <<<"$body"); data=$(head -n -1 <<<"$body")
  if [[ "$code" == "401" || "$code" == "403" || "$code" == "404" || "$data" == "[]" ]]; then ok "anon cannot read $t ($code)"; else bad "anon read $t → $code $data"; fi
done

# 4. the public knowledge base answers through its RPC (no table access)
branch=$(curl -s "$api/rest/v1/branches?select=id&is_active=eq.true&limit=1" -H "apikey: $key" -H "Authorization: Bearer $key" | grep -o '"id":"[0-9a-f-]\{36\}"' | head -1 | cut -d'"' -f4)
if [[ -z "$branch" ]]; then branch="${VITE_DEFAULT_BRANCH_ID:-}"; fi
if [[ -n "$branch" ]]; then
  code=$(curl -s -o /tmp/kb.json -w "%{http_code}" "$api/rest/v1/rpc/fn_public_knowledge" -X POST -H "apikey: $key" -H "Authorization: Bearer $key" -H "Content-Type: application/json" -d "{\"p_branch\":\"$branch\"}")
  [[ "$code" == "200" ]] && ok "fn_public_knowledge → 200 ($(grep -o '"question"' /tmp/kb.json | wc -l) entries)" || bad "fn_public_knowledge → $code"
fi

# 5. the AI reception edge function answers (deterministic path works without any model key)
payload='{"message":"مرحبا","channel":"screen"}'
[[ -n "$branch" ]] && payload="{\"message\":\"مرحبا\",\"channel\":\"screen\",\"branch_id\":\"$branch\"}"
code=$(curl -s -o /tmp/rec.json -w "%{http_code}" "$api/functions/v1/ai-reception" -X POST -H "apikey: $key" -H "Authorization: Bearer $key" -H "Content-Type: application/json" -d "$payload")
if [[ "$code" == "200" ]] && grep -q '"reply"' /tmp/rec.json; then ok "ai-reception → 200 with a reply"; else bad "ai-reception → $code $(head -c 200 /tmp/rec.json)"; fi

[[ $fail -eq 0 ]] && echo "SMOKE: PASS" || echo "SMOKE: FAIL"
exit $fail
