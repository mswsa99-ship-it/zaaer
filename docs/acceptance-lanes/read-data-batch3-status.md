# read-data batch 3
Proof: tests/isolation/read-data-batch3-proof.sql (base fixtures.sql only, one rolled-back transaction, strict gate). 628 calls, 0 failures.
Covers: fn_authorize_export, fn_invoice_preview, fn_reports_capability_usage, fn_branch_media, fn_branch_photo, fn_public_review.
Markers: branch names MK-BR-<code>, logo/photo mime image/mk-<code> bytes, review tokens MKTOK-/MKEXP-<code>, audit actions mk_act_<A|B|O>.
Public contexts: slug own / other hotel / unknown, no header, service_role, x-guest-token own and foreign, inactive branch, archived photo, expired and garbage review tokens.
Limits: role sets from the permission seed (invoice.issue, reports.identities_usage), not independently derived; invoice preview oracle is identity + charge ownership + total consistency (not a recomputed price); the authenticated-with-no-header path of the public reads (staff seeing own branch) is not asserted; the platform five stay review-only.
