# Local synthetic e-invoice seam qualification

Source anchors: migration0091_invoice_credit_note, effective fn_issue_credit_note and fn_cancel_invoice; existing tests/sql/phase4_controls_tests.sql lines48–49use the same server-side state injection.

Repository source search found only the e_invoice_ref column and credit-note/cancel guards, not a reporting transport or a production RPC that submits an invoice to an authority. The local prerequisite is simply a non-NULL invoices.e_invoice_ref. Do not invent such a transport or imply the test marker was reported externally.

Safe test-only seam: issue a real invoice through fn_staff_issue_invoice under its owner, then as the disposable database test server set a conspicuous `SYNTHETIC-LOCAL-NOT-REPORTED` e_invoice_ref on that invoice. No function mocked, permission broadened, trigger disabled or outbound integration invoked. Register a separate purpose such as `einv` if integrated into isolation fixtures so normal invoice victims and cancel adapters stay unchanged. Never overwrite a normal victim or automatically mark all invoices.

## Executed focused proof

On fresh-migrated local PG16iso_candidate_1733, tests/isolation/einvoice-seam-proof.sql runs in one transaction and rolls all fixtures/changes back:

- Real owner/category/source/reservation/invoice issuance succeeds, positive invoice amount checked.
- Same-hotel other-branch manager and other-hotel owner are denied by actual42501/FORBIDDEN guards.
- After denials, no credit note, credit review or credit audit exists.
- Cancellation of the synthetically reported invoice refuses E_INVOICED_USE_CREDIT_NOTE.
- Empty reason refuses, real owner credit-note call succeeds, duplicate refuses.
- Original remains issued; credit note has exact parent/stay/branch/hotel, copied amounts/snapshot/bill-to/report marker, its own number, exactly one review and one audit.

This is local source-path and synthetic prerequisite proof, not actual e-invoice reporting, broad role-matrix acceptance or exact global non-target proof.

## Contract for subsequent exact adapter work

The real implementation may insert invoices, advance organization-level document_sequences, insert review_items and audit_events, and invoke invoice-table triggers. Independent adapter validation must snapshot the effective loaded schema to enumerate all actual changed rows. Expected original invoice is unchanged; one credit-note insert, exact review/audit inserts and correct sequence advance should be checked. Include exact touched-row/non-target contracts, owner positive controls and same-hotel foreign-branch plus cross-hotel negative actors. Keep the base unreported path distinct; it should retain NOT_E_INVOICED and cannot be credited as a permission denial.

This patch intentionally does not change shared fixture files, adapters, inventory status, guest capability actors, production migrations or application code. Coordinator routes the seam to those owners.

## Canonical fixture and adapter25integration supplement

Extracted only the einv block from the cumulative fixture packet and only the one #einv adapter row. Purpose-isolated four invoices are issued through the real owner invoice path then carry the explicit synthetic marker. Base unreported credit-note row remains unchanged; protected9remain excluded.120unique adapters,338inventory signatures, no inventory status promotion.

Independent local PG16recheck on canonical enginef98d13e(no rejected18header injection):20focused probes,4owner controls exact,4own-branch manager effects exact,12foreign actor42501permission denials (same-hotel other-branch manager, other-hotel owner, other-hotel manager per target). Successful controls/own actors report effect=asserted-ok and nontarget=proved-rowlevel, four changed tables: invoices/document_sequences/review_items/audit_events. All successful probe mutations rolled back. See credit-einv-focused-proof.sql.

Setup used a local cloned migrated test DB plus canonical base fixture. Attempting the all-family rpc-fixtures preload failed atomically at missing local app.keybox_key; no keybox call succeeded and that attempt is not proof. Continued with only real direct-source creation plus the isolated einv fixture, avoiding unrelated keybox/guest work. Both setup attempts/logs retained locally. Focused proof does not depend on the unrelated failed preload.14static invariant cases and39isolation report/matrix/skip unit tests pass. No production effect, real reporting, full matrix acceptance or credit for base invalid controls.
