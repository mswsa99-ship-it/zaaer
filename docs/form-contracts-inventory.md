# Form/list contracts, worker I inventory

Base: `1325919`. Scope: source inventory plus local demo-browser tests. No production deployment, database, account, or outbound communication was used. This is a gap register, not an acceptance certificate. All five item-level acceptance cells remain **partial / not accepted live**.

## What changed

| Location | Change | Evidence | Still open |
| --- | --- | --- | --- |
| `src/components/forms.tsx` | ActionForm uses a synchronous ref lock; new opt-in session draft hook and restore banner | Slow same-tick category save writes once; explicit restore and delayed second reload | Other ad-hoc handlers do not inherit this lock; stored JSON shape/version/expiry validation; logout and branch-switch cases |
| `src/pages/staff/Tickets.tsx` | Ref lock around ticket creation | Two same-tick submits, 800ms RPC response, one RPC and one ticket | Other ticket actions; full offline retry and cross-tab replay |
| `src/pages/staff/Inbox.tsx` | Ref lock around sendReply | Same-tick submit, delayed message reload, one displayed reply, lock eventually releases | Insert itself is synchronous in demo; no slow production WhatsApp send or backend idempotency proof |
| `src/pages/admin/AdminRoomCategories.tsx` | New-record draft, scoped by branch; explicit restore; clear on successful save | Fill/reload/reopen/restore all text and price fields; wait/reload again before restore | Edit-record drafts, branch switching, storage-denied behavior and all non-text fields lack browser tests |
| `src/pages/admin/AdminServices.tsx` | New-record draft, scoped by branch | Fill/reload/restore text and price | Edit drafts and every toggle/select variant lack browser tests |
| `src/pages/admin/AdminBranches.tsx` | New-record draft, scoped by organization; load failure is one error state and retry; clear stale error | Branch draft reload/restore and injected read failure/recovery | Edit drafts; every tax control; secondary room-count failure handling |
| `src/pages/admin/AdminBookingSources.tsx` | Load failure is one error state with retry; clear stale error on success | Injected read failure/recovery | Toggle and create/update write races not individually exercised |
| `tests/e2e/global_form_contracts.spec.ts` | 21 tests: 3 draft, 12 admin list, 3 same-tick save, 3 disabled-reason | Final desktop run green | Not mobile, Firefox, WebKit or real backend coverage |
| `tests/unit/copy_terms.test.ts` | Three preventive spelling bans, no API key or identity rename | 3 unit tests green | Scanner covers source text, not rendered UI semantics |

No design tokens or shared verify/package/workflow files changed. Existing visual classes were reused. No wiring patch is needed: the existing `tests/e2e` and `tests/unit` discovery paths include the new spec and updated scanner. CI execution itself was not run.

## Contract 6.5, draft coverage

A new draft is an opt-in convenience, not a silent server save. Data stays in this browser tab's session storage, offered back for the user to restore. It clears on successful save, not on failed save. Persistence is debounced 300ms, so typing immediately followed by reload can still lose the last keystrokes. Closing the tab ends the session; cross-device recovery is not claimed.

| Forms | Current evidence / next step |
| --- | --- |
| New category, service, branch | Implemented and tested as above. Editing existing records deliberately not persisted by this hook, so global no-loss acceptance is not met. |
| Expenses | Existing session draft; existing `k_draft` regression passes. Not a new implementation in this series. |
| StaffReservationNew | Existing session draft by branch. Source inventory only here; wizard disabled reason tested. Stay-cycle ownership collision, no edits. |
| AdminRooms, AdminKnowledge, AdminPolicies, AdminStructure, AdminCashAccounts, AdminProducts | Long/new/edit forms use component state with no useFormDraft integration found. Draft proposals, not fixed. |
| AdminOrganization, AdminAiSettings, AdminJourney, AdminAvailabilityRules, AdminRates | Multi-field settings/editors need save/no-loss review. Saved server settings are not an unsaved-input draft. |
| AdminFacilities, AdminTaskTypes, AdminStaff, AdminBookingSources, AdminRoles | State-only editors or shorter forms; classify intended draft threshold and test reload behavior before accepting. |
| Registration, BookingNew, CheckIn, GuestReview and guest child forms | Need separate privacy-aware recovery policy. Do not persist identity documents, passwords or access tokens as a generic draft. No implementation claimed. |
| Account, ResetPassword, StaffLogin | Password fields must not use generic session drafts. Lead owns StaffLogin; no edits. |
| Tickets, Inbox, Codes, PosSettlement, BankMovements and reservation-detail actions | State-only ad-hoc inputs; no universal draft promise. Need per-form policy and replay tests. |
| Owner/setup, platform and finance-settings flows | Ownership boundary. No changes; excluded from dynamic acceptance. |

## Contract 6.6, list-state coverage

12 admin routes were tested with the demo's `__demoFail` hook, then recovery by retry or route re-entry. Each must show exactly one error alert under failure; it may not simultaneously show an empty state or spinner. On recovery it must show no alert or spinner. These tests do **not** prove every data/empty permutation, stable data during background revalidation, real browser-offline behavior or successful data content after recovery. Existing code can retain stale data next to an error banner, so the strict global XOR is not certified.

Admin routes exercised: room-categories, services, rooms, facilities, task-types, structure, cash-accounts, booking-sources, branches, staff, knowledge, policies.

Existing `k_list_states` exercises 13 staff routes: expenses, ledger, arrivals, reservations, payments, tickets, housekeeping, codes, followups, orders, bank, platforms, identity-verification. It passed in the final regression run, but has weaker initial-error assertions than the new admin sweep.

All other page files are enumerated below. They have not been promoted to PASS by a source match. Tab-specific lists such as Knowledge unanswered entries, nested modal lists, search/filter empty states and secondary queries require separate browser assertions.

## Contract 6.7, save locks

- Shared ActionForm now blocks re-entry synchronously before React renders disabled state, and releases the lock in finally on success or failure.
- Tickets create and Inbox reply have equivalent ref locks. Other handlers in those same pages are not covered by that change.
- Existing Expenses and reservation save guards were retained; their existing regression specs pass.
- Ad-hoc handlers including Account, Codes, PosSettlement, availability inline editors, settings saves and status toggles still require explicit same-tick tests. A disabled button or `setBusy` alone is not a proof.
- Client locks do not replace server idempotency, and do not prevent duplicate actions from another tab, device or a retried request after an ambiguous response.

## Contract 6.8, disabled reasons

The automated source scan is only a candidate finder. It cannot see a reason in a parent section. A line with no adjacent hint is not automatically a defect.

| Location / condition | Review result |
| --- | --- |
| AdminAiSettings non-owner controls | Existing page-level read-only reason. Browser verified. No changes. |
| AdminJourney non-owner controls | Existing section-level owner-only reason. Browser verified. No changes. |
| Reservation wizard next step | Existing aria-describedby and visible reason. Browser verified. No changes. |
| AdminOrganization non-owner fields | Existing read-only banner in source. Not dynamically tested here. |
| AdminFacilities / AdminRooms floor before block | Existing Field hint tells user to choose block first. Source only. |
| AdminBranches tax privilege and tax-off rate | Fieldset owner-only legend and on/off labels are present; all variants not dynamically certified. |
| AdminProducts missing categories | Existing explanatory block. Source only. |
| BranchGuideEditor archived caption / empty video URL, ExportMenu zero-count items, Invoices failed preview, ReceptionChat thinking/empty input | Candidate reason/accessibility work. Parent context and exact condition need a visual check before changing copy. |
| Pagination previous at first page, empty reply or order quantity | Obvious to some users is not acceptance evidence. Need visible or associated explanation and keyboard/screen-reader checks. |
| Busy/spinner-only actions | Spinner conveys progress visually, but reason/status announcement and all disable causes need separate validation. No global PASS. |

## Ownership and merge proposals

- `forms.tsx` is a shared collision spot. Merge its small patch before page consumers. It must not overwrite design/token work.
- StaffReservationNew, StaffReservationDetail, StayCycle and GuestJourney: source inventory and existing tests only. No edits. Coordinate any draft/disabled-reason work with their owner.
- Lead-owned auth/App/login/owner setup/demo/platform/migration files remain untouched.
- Worker D finance-settings page/helpers/demo adapter/migration 0099 remain untouched.
- COPY_GUIDE counts and approval claims were not treated as permission. The separate copy review reports source counts and proposals; locked terminology dictionaries were not changed.

## Full source surface inventory

The following per-file ledger records literal form, ActionForm, disabled, list-state and draft markers. Counts locate review work, not semantically distinct forms or acceptance. Nested editors in shared components are included. A zero does not mean a page has no form: imported components can own it. Every non-tested row remains **ما جُرب** dynamically in this packet. Protected files are inventoried, never edited.

| File | `<form` lines | ActionForm lines | disabled lines | List state markers | Draft markers |
| --- | --- | --- | --- | --- | --- |
| `src/components/AppErrorBoundary.tsx` | - | - | - | - | 17, 29 |
| `src/components/BottomTabs.tsx` | - | - | - | - | - |
| `src/components/BranchGuideEditor.tsx` | - | - | 78, 93, 104, 126, 139 | - | - |
| `src/components/BranchPicker.tsx` | - | - | - | - | - |
| `src/components/DailyBriefing.tsx` | - | - | - | - | - |
| `src/components/DemoBanner.tsx` | - | - | - | - | - |
| `src/components/ExportMenu.tsx` | - | - | 54, 60, 78 | - | - |
| `src/components/GuestBranchGuide.tsx` | - | - | - | - | - |
| `src/components/GuestJourney.tsx` | - | - | 139, 158, 165, 177, 201, 204, 208 | - | - |
| `src/components/GuestLinkError.tsx` | - | - | - | - | - |
| `src/components/Guests.tsx` | - | 90, 107, 137, 183, 258 | 229, 366 | - | - |
| `src/components/HBars.tsx` | - | - | - | - | - |
| `src/components/Invoices.tsx` | - | 126, 173, 208 | 105, 153 | - | - |
| `src/components/KeyboxAlert.tsx` | - | - | - | - | - |
| `src/components/OpsCopilot.tsx` | 143 | - | 144, 145 | - | - |
| `src/components/OwnerOverview.tsx` | - | - | 104 | - | - |
| `src/components/PrintButton.tsx` | - | - | - | - | - |
| `src/components/ReceptionChat.tsx` | 167 | - | 168, 169 | - | 48, 49, 50, 51, 83, 97 |
| `src/components/RequireRole.tsx` | - | - | - | 46 | - |
| `src/components/ReservationCard.tsx` | - | - | - | - | - |
| `src/components/ReservationOperations.tsx` | - | 222, 247, 312, 353, 412, 438, 462, 486, 521 | - | - | - |
| `src/components/ReviewBanner.tsx` | - | - | - | - | - |
| `src/components/ShiftBoard.tsx` | - | - | - | - | - |
| `src/components/StayCycle.tsx` | 101 | 168, 349, 429, 461 | 108, 115, 249, 286 | - | - |
| `src/components/StayProgress.tsx` | - | - | - | - | - |
| `src/components/WhatsAppEntry.tsx` | - | - | - | - | - |
| `src/components/WindowedList.tsx` | - | - | - | - | - |
| `src/components/forms.tsx` | 128 | - | 79, 96, 108, 119, 238, 255 | - | 144, 148, 163, 176, 177, 184 |
| `src/components/roomai.tsx` | - | - | - | - | - |
| `src/components/ui.tsx` | - | - | - | 80, 81, 82 | - |
| `src/pages/DesignGallery.tsx` | - | - | 36 | - | - |
| `src/pages/admin/AdminAiSettings.tsx` | - | - | 185, 186, 187, 188, 191, 198, 204, 209, 210, 211, 212, 213, 214, 215, 221, 222, 223, 224, 225, 226, 233, 234, 235, 236, 241, 246, 259, 375, 404 | 169 | - |
| `src/pages/admin/AdminAssistant.tsx` | - | - | - | - | - |
| `src/pages/admin/AdminAuditLogs.tsx` | 170 | - | 123, 175 | - | - |
| `src/pages/admin/AdminAvailability.tsx` | - | - | 78, 81, 84 | 47, 60 | - |
| `src/pages/admin/AdminAvailabilityRules.tsx` | - | - | 87, 91, 95, 99, 116, 173, 174 | 56, 68 | - |
| `src/pages/admin/AdminBankMail.tsx` | - | 180, 206 | 79, 92, 102 | 66 | - |
| `src/pages/admin/AdminBookingSources.tsx` | - | 78, 90, 115 | 70 | 48, 54 | - |
| `src/pages/admin/AdminBranches.tsx` | - | 87 | 111, 125, 187, 188 | 60, 67 | 9, 57 |
| `src/pages/admin/AdminCashAccounts.tsx` | - | 111, 135 | - | 48, 105 | - |
| `src/pages/admin/AdminDashboard.tsx` | - | - | - | 93, 98, 99 | - |
| `src/pages/admin/AdminDataPurge.tsx` | 202 | - | 121, 131, 158, 183, 196, 206, 207 | - | - |
| `src/pages/admin/AdminFacilities.tsx` | - | 62 | 67 | 35, 44 | - |
| `src/pages/admin/AdminFinance.tsx` | - | - | 67, 109 | - | - |
| `src/pages/admin/AdminGuests.tsx` | - | 184 | - | 47, 61, 112 | - |
| `src/pages/admin/AdminIntegrations.tsx` | - | - | - | - | - |
| `src/pages/admin/AdminJourney.tsx` | - | - | 118, 142, 143, 202, 223, 232, 296, 297, 298, 299, 300, 306, 326 | 63 | - |
| `src/pages/admin/AdminKnowledge.tsx` | - | 154, 202 | 120, 142, 185 | 69, 96, 129 | - |
| `src/pages/admin/AdminOrganization.tsx` | - | - | 79, 80, 81, 85, 93, 94, 107, 108, 114 | 62, 63 | - |
| `src/pages/admin/AdminPaymentProviders.tsx` | - | - | 87, 88 | 61, 62 | - |
| `src/pages/admin/AdminPlatformPayouts.tsx` | - | 136, 161 | 110 | 68, 77, 80 | - |
| `src/pages/admin/AdminPolicies.tsx` | - | 117, 140 | - | 64, 86, 87, 88 | - |
| `src/pages/admin/AdminProducts.tsx` | - | 120, 136 | 49, 97, 245 | 40, 62 | - |
| `src/pages/admin/AdminRates.tsx` | - | 174, 209 | 78, 142, 194 | 43, 64, 81 | - |
| `src/pages/admin/AdminReports.tsx` | - | - | 208 | 131, 135, 261 | - |
| `src/pages/admin/AdminReservations.tsx` | - | - | - | - | - |
| `src/pages/admin/AdminReview.tsx` | - | - | 89, 96, 97, 179, 191, 195 | - | - |
| `src/pages/admin/AdminRoles.tsx` | - | 109 | 76, 154 | 65, 66 | - |
| `src/pages/admin/AdminRoomCategories.tsx` | - | 73 | - | 44, 52 | 7, 42 |
| `src/pages/admin/AdminRooms.tsx` | - | 82 | 93 | 44, 57 | - |
| `src/pages/admin/AdminServices.tsx` | - | 63 | 69 | 36, 44 | 7, 34 |
| `src/pages/admin/AdminStaff.tsx` | - | 188, 230, 245 | 137, 175, 176, 198, 205, 212 | 100, 101, 144 | - |
| `src/pages/admin/AdminStructure.tsx` | - | 94, 109 | - | 38, 50 | - |
| `src/pages/admin/AdminTaskTypes.tsx` | - | 55 | - | 29, 37 | - |
| `src/pages/admin/AdminUsage.tsx` | - | - | 44 | 61 | - |
| `src/pages/admin/AdminWhatsapp.tsx` | - | - | 102, 139, 147, 148, 152, 160, 189, 197, 254, 255, 256, 339, 346 | 371 | - |
| `src/pages/admin/PlatformHotels.tsx` | 17 | - | 17 | 16 | - |
| `src/pages/guest/BookingLookup.tsx` | 134, 143, 156 | - | 136, 145, 161, 170 | - | 43, 52, 56, 109, 170 |
| `src/pages/guest/BookingNew.tsx` | - | - | - | - | - |
| `src/pages/guest/BookingStatus.tsx` | - | - | 172 | - | - |
| `src/pages/guest/CheckIn.tsx` | - | - | 82 | - | - |
| `src/pages/guest/GuestReview.tsx` | 84 | - | 97 | - | - |
| `src/pages/guest/Kiosk.tsx` | - | - | - | - | 20 |
| `src/pages/guest/Landing.tsx` | - | - | - | - | - |
| `src/pages/guest/Privacy.tsx` | - | - | - | - | - |
| `src/pages/guest/Registration.tsx` | 276 | - | 162, 174, 349 | - | - |
| `src/pages/guest/StaySummary.tsx` | - | - | 50 | - | - |
| `src/pages/guest/Terms.tsx` | - | - | - | - | - |
| `src/pages/guest/WhatsAppDemo.tsx` | 148, 159 | - | 146, 149, 150, 160, 161 | - | - |
| `src/pages/staff/AccessApprovals.tsx` | - | - | - | 28, 29, 46, 49, 54 | - |
| `src/pages/staff/Account.tsx` | 68 | - | 78, 82, 91 | - | - |
| `src/pages/staff/Accounts.tsx` | - | 245 | - | 80, 99, 196 | - |
| `src/pages/staff/Arrivals.tsx` | - | - | - | 13, 14, 29 | - |
| `src/pages/staff/BankMovements.tsx` | - | 161, 210, 234, 248 | - | 81, 98, 282, 283 | - |
| `src/pages/staff/Codes.tsx` | 253 | - | 202, 212, 273 | 103, 122 | - |
| `src/pages/staff/DayClosing.tsx` | - | 235, 271, 327, 350 | 136, 142, 143, 191, 194, 261 | 78, 289 | - |
| `src/pages/staff/DaySummary.tsx` | - | - | - | 24, 35, 36 | - |
| `src/pages/staff/Expenses.tsx` | 239 | 114, 180 | 235, 241 | 76, 77 | 148, 152, 155, 186, 193 |
| `src/pages/staff/Housekeeping.tsx` | - | 135, 159, 165, 171, 190 | 104, 105 | 70, 71, 82, 128 | - |
| `src/pages/staff/IdentityVerification.tsx` | - | - | - | 25, 26, 36 | - |
| `src/pages/staff/Inbox.tsx` | 216 | - | 178, 183, 218 | 137, 147, 148 | - |
| `src/pages/staff/Ledger.tsx` | - | 110 | - | 61, 75 | - |
| `src/pages/staff/PlatformCheck.tsx` | - | - | 53 | 27, 34 | - |
| `src/pages/staff/PosSettlement.tsx` | 148 | - | 153 | 43, 49, 50, 101 | - |
| `src/pages/staff/ProductOrders.tsx` | - | 169, 201, 242 | 260 | 92, 93, 237, 239, 240 | - |
| `src/pages/staff/ResetPassword.tsx` | 90 | - | 102 | - | - |
| `src/pages/staff/Shortcuts.tsx` | - | - | - | - | - |
| `src/pages/staff/StaffDashboard.tsx` | - | - | - | 31, 37, 108, 138 | - |
| `src/pages/staff/StaffJourney.tsx` | - | 271, 286, 303 | - | 92, 119, 136, 162, 177, 193, 248 | - |
| `src/pages/staff/StaffLogin.tsx` | 93 | - | 123 | - | - |
| `src/pages/staff/StaffPayments.tsx` | - | - | - | 29, 30, 40 | - |
| `src/pages/staff/StaffReservationDetail.tsx` | - | 442 | 249, 271, 339 | 170 | - |
| `src/pages/staff/StaffReservationNew.tsx` | 169 | - | 138, 188, 301, 314 | 155 | 49, 53, 58, 125, 161 |
| `src/pages/staff/StaffReservations.tsx` | - | 279 | 198, 272 | - | - |
| `src/pages/staff/StaffRooms.tsx` | - | - | - | 95, 96, 148 | - |
| `src/pages/staff/StayFollowups.tsx` | - | - | - | 20, 21 | - |
| `src/pages/staff/Tickets.tsx` | 210 | - | 192, 220, 242 | 151, 152, 166, 228 | - |
