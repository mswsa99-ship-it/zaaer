# 6.5 increment: branch settings and knowledge edits

Base: candidate a10ef32 with gate WIP, 2026-11-24 18:03. Local demo only.

- Branch edit: uses existing useEditDraft with user, organisation and record key; version mismatch drops saved edit. Phone, email, address, tax/registration identifiers and arbitrary URLs are omitted. Visible notice explains these fields are not recovered. Existing new-branch draft behavior is unchanged by this patch.
- Knowledge edit: same scoped/versioned hook, normal form shape plus pending keyword input. Restore is explicit; failed save keeps draft, successful save clears it. No guest/identity/password form changes.
- Targeted browser tests: 9 passing with one Chromium worker. Widths 1280 and 390: saved record shown before explicit restore; injected RPC failure retains storage; retry saves and clears; untouched form stores nothing; same-record unchanged-version positive control then envelope mismatch drops; wrong user/org/record keys not offered; pending keyword restored.
- A separate existing-form draft subset: 16 passing. Typecheck and theme guard pass.
- Screenshots inspected: branch edit offer at 390, knowledge offer at 390 and 1280, branch saved at 1280, knowledge saved at 390. Banners/notice readable; long mobile modal scrolls to later fields and save.

Not claimed: real backend version bump/revocation, session lifecycle as a whole, Firefox/Safari/device coverage, every field/toggle combination, universal no-loss coverage. Branch excluded fields deliberately do not survive reload. Policy/cash-account/product/structure and other long-form edit drafts remain open. Existing shared hook validation/expiry limits are unchanged.

Canonical supplement18:14: clean patch integrated above61cf7cb, fresh demo build/tsc/theme pass. Isolated preview4197with system Chrome:9/9in2completed disjoint batches(1+8). Initial wrong-project/missing-managed-browser attempts were infrastructure failures; an accidental reused4174old-source preview run failed and timed out, excluded. Do not treat those as current-source acceptance or hide them. Inspected actual390branch and knowledge offered-draft PNGs: readable banners/notice and aligned fields, long modal scrolls. No global no-loss/Safari/real backend race claim. Gate P0isolation blocker preserved.
