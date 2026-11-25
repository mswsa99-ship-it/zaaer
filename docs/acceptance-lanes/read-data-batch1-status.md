# read-data lane, batch 1: qualified identity proof status

Proof file: `tests/isolation/read-data-batch1-proof.sql` (one transaction, rolled back, strict gate with `-v strict=1`).
Run on a disposable PG16.16 socket DB after bootstrap + all migrations + `engine.sql` + scope SQL + `fixtures.sql` + `rpc-fixtures.sql`.
No fixture, migration, engine or gate file was edited. Markers are stamped on existing fixture rows inside the transaction.

## Covered (24 of the 40 read-data signatures), 592 real authenticated calls

Actors: hotel-a owner, hotel-a branch-1 manager/supervisor/finance/housekeeping, hotel-a branch-2 manager, hotel-b owner, hotel-b branch-1 manager.
Targets for branch/category functions: own branch 1, own branch 2 (same hotel), other hotel branch 1. Third legacy org `0000...0001` is stamped as a decoy.
Individual-mode states (no row / empty grants / matching page view / other page only) run for page-gated functions.

| Kind | Functions |
| --- | --- |
| branch scoped, capability gate | fn_admin_payment_settings (security), fn_admin_journey_settings, fn_admin_media_items, fn_admin_branch_media_info, fn_admin_unit_guides (branch.settings), fn_staff_product_menu (voucher.receipt), fn_category_capacity_impact (definitions) |
| branch scoped, branch membership only | fn_staff_knowledge (denial is an empty array, by design), fn_report_filter_options (denial is `{}`) |
| branch scoped, page + role | fn_room_licenses, fn_price_limits (foreign category returns null) |
| org scoped | fn_admin_bank_mail_get, fn_admin_purge_history, fn_admin_trial_overview, fn_admin_whatsapp_channels, fn_audit_chain_verify, fn_organization_info, fn_my_page_access, fn_saved_views_list, fn_review_summary (null without review.list), fn_bank_poll_allowed |
| org scoped, page + role | fn_admin_alert_rules, fn_review_list, fn_lookup_trace |

Assertions per allowed call: no error, no marker of another hotel/branch/legacy org, required own markers present, exact oracle (ids or counts or values) computed as superuser from the target rows. Per denied call: error 42501 `FORBIDDEN%` or the documented null/empty/`{}` result (any other error text counts as a failure). After each actor a whole-catalog `iso.snap()` diff must be empty (reads write nothing). The staff_page_access rows this harness changes are restored before the diff.

Result on clean build: 592 calls, 0 failures (202 allowed-and-correct, 382 denied-and-correct, 136 foreign-hotel calls, 8 no-write snapshots).

## Mutation check (discriminating power)
On a copy of the DB, nine functions were weakened one at a time (drop branch check, drop capability check, drop org filter, include pending purge rows, foreign trace lookup, volatile write). The proof failed for journey settings, payment settings, knowledge, organization info, audit chain, lookup trace, purge history and the no-write snapshot. One weakening was not caught: fn_review_summary without its branch filter, because only the owner passes `review.list`, and an owner sees every branch, so the change has no observable effect for any allowed role. The copy was dropped.

## Not covered (explicit remaining)
- Reserved: fn_admin_products (0118 fix, matrix worker).
- Platform/exit/status names that need extra scope review before any execution: fn_platform_hotels, fn_platform_operator_id, fn_hotel_exit_tables, fn_hotel_exit_verify, fn_backup_status.
- Not yet read or adapted: fn_definition_dependencies, fn_invoice_preview, fn_quote_stay, fn_reports_capability_usage, fn_authorize_export (void gate), fn_ai_ops_allowed_actions and fn_purge_categories (constant literals, belong to the utility lane).
- Public/anon reads needing header/token fixtures: fn_branch_media, fn_branch_photo, fn_public_review.
- Limits: no valid-empty contrast per function (every positive here is data-bearing instead). Role matrix for capabilities is taken from effective runtime behavior and the 0043 seed (branch.settings owner,manager), not from a second independent oracle. Individual-mode capability paths (fn_can via permission_page_map) are not exercised for capability-gated functions, only page-gated ones. Same-hotel cross-branch reads for non-owners are denied or empty in every covered function. Not run against the integrator's canonical PG16 instance.
