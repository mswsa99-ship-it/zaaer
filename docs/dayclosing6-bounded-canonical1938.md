# dayclosing6, bounded cash-neutral qualification

Supplied full source roomai-canonical68f801f-plusmoney-source, through migration0121. Fresh disposable PG16 bootstrap+migrations only, no broad base/rpc/variant fixture loading. Net new standalone test; no migrations, engine, adapters or production files changed.

124 assertions PASS, set constraints all immediate succeeds, final ROLLBACK. Zero residual synthetic organizations and zero outbox. Sources/grants/hooks and raw output attached. No bank/email/integration/network/Auth/protected calls.

## Exact synthetic state

Two hotels with two branches each, branch-member managers and separate hotel owners. Branch creation seeds its own cash/bank accounts and GL chart. No vouchers, expenses or bank movement fixtures are loaded. Day zero system totals for cash, POS and transfer are explicitly asserted. Entered cash=0, POS=250 with literal explanation, bank_transfer=0. After review/submit, amendment changes only POS to300 with explanation. This is a valid nonzero terminal discrepancy with zero cash discrepancy; it deliberately does not exercise GL cash posting. Existing synthetic reservations are inert on the previous business date and have no paid vouchers.

## Six positives

- save updates an actual draft with three exact lines and note/version2; separate new-day save inserts draft/version1 plus exactly three lines and created audit.
- review on valid draft returns no missing/unexplained boxes, valid review token, version2 and three system-zero boxes. Snapshot permits only its closing/lines changes.
- submit takes the real issued token/version2 and stores submitted_by/time/edit window/version3, clears token, freezes figures and adds exact submission audit identity/action/business-date/three lines. Bad token is separately labelled validation, not permission denial.
- amend inside valid window changes POS250 to300, advances version4, writes one review item with literal reason/actor and one amendment audit. Exact line deltas one update. Repeat with same content reports unchanged and no public-row changes.
- request_edit uses directly seeded expired edit window on submitted closing, inserts one pending request with literal reason/requester/org/branch plus audit. Duplicate request and self-decision are labelled separately.
- decide by real hotel owner approves an actual request, updates request actor/note/time and closing version5/exact edit deadline, adds approval audit. A second valid expired-window request is rejected, changing only request and audit, not closing.

Every API call checks zero outbox and no enabled keyed bridge before/after; unsafe state raises before invocation. Actual authenticated/anon roles with cleared/replaced claims. Wrong-branch and foreign-hotel explicit objects use the same manager as positive. All six have explicit individual-no-page denial. Whole-public snapshots reject unexpected table changes; allowed-table changes are further restricted to the target branch, so other-branch/foreign-hotel decoy rows remain exact. Audits check actor/org/branch/entity/action and key literal contents. Row insert/update/delete counts checked, including exact 3-line or 1-line updates. All writes rollback.

## Limits and canonical work

Canonical integrator must rerun/register bounded evidence; not generic adapter matrix or release PASS. Zero system-money/cash-difference case only. Nonzero cash discrepancy GL posting/reversal, journal entries/lines/document numbering, voucher/expense-derived system figures, missing/excess source boxes and finance threshold alerts remain uncovered. No blanket ledger claim. Review uses real issued token but summary hash binding mutant not run. Owner approve/reject is tested, not distinct manager approver, positive individual grants, view-only or every disallowed role. Foreign-hotel decide negative additionally reuses the positive owner; wrong-branch controls use manager because owner can access all hotel branches. No repeated policy migration or production repair.

Canonical integration19:38:2ca02b3 PG16.6 iso_candidate_pages1902, originally migrations-only through0120 then0121+0122 applied before proof, no base/rpc fixture preload. Actual124/124 true, SET CONSTRAINTS ALL IMMEDIATE and ROLLBACK completed. Runtime~90seconds wholepublic JSON scans, no duplicate launch. Existing synthetic base from previous proofs absent because rollback. No full acceptance credit.
