# read-data batch 2
Proof: tests/isolation/read-data-batch2-proof.sql (needs only base fixtures.sql). Covers fn_definition_dependencies (entity=branch) and fn_quote_stay: 182 calls, 0 failures.
Limits: dependencies only entity=branch (other entities and page-gate states not exercised); quote_stay only daily basis, no tax/platform/discount; role matrix for dependencies is the observed legacy matrix.
Not done: fn_invoice_preview, fn_reports_capability_usage, fn_authorize_export, public/anon reads, platform/exit/status reads (review only).
