# Scoped branch-read repair, local candidate 2026-11-24

Base:184a6c8. User instruction to fix the confirmed same-hotel cross-branch disclosure, received17:15 Riyadh. This local repair does not authorize publication or live migrations.

## Changes

- Four restrictive authenticated SELECT policies require both current hotel and current branch membership for ai_guardrail_events, ai_tool_executions, branch_memberships and product_branches. Existing permissive role/page predicates still govern whether a read is granted. No write grant is added. Owner membership helper already resolves all branches of their own hotel.
- fn_admin_staff_list keeps the hotel registry identities and existing phone/capability gates. Only the active branch_ids aggregate is filtered to branches the caller can access, including for self rows. Removed memberships are still excluded.
- Hotel finance settings and audit NULL-branch privacy are unchanged. No isolation report/oracle reclassification. No protected RPC execution.
- Page-RLS structural test now checks page helpers on permissive granting SELECT policies. Restrictive policies only AND/narrow that permission. Added exact identity/scope check for all four restrictions, not a blanket exception.

## Evidence

Fresh disposable PG16iso_branchfix1717, all canonical migrations through0113, synthetic transactional fixture:

- Red:76 assertions,13 failures before0114. Reproduced manager AI reads2, membership/product reads8 across four nonowner roles, staff branch metadata1, individual AI page-grant reads2.
- Green:76/76 on same script after0114. Final added inactive/no-page checks bring focused suite to79/79.
- This smaller fixture does not replace independent40-cell validation or establish full isolation acceptance.

Fresh PG16iso_branchfix_ordered1719 applied all migrations including0114 and the original ordered fixture/test chain from platform through permissions, then boundary tests. Completed without errors, including lists_reports59/59 and permissions20/20. A prior shortcut had skipped required fixture suites and produced four audit/options failures. Those results were discarded; no product code changed to fit them.

Additional verification:

- Permission-draft SQL45 assertions pass.
- Page-RLS33/33 after the precise structural correction. Original behavioral checks all retained. A separate local template clone avoided duplicate persisted page fixtures.
-28 unit tests pass across tenancy, permissions, individual permissions and catalog parity.
- Static RPC inventory unchanged338exposed,9protected,119unique adapters.

Independent isolation worker validation remains requested via main. No full matrix acceptance, live migration, publication, Auth/SMTP changes, external message or spending.

## Consumer semantics supplement

Independent validation reported via main: all40 previously confirmed same-hotel foreign-branch read cases closed, with own/owner/cross-hotel/write outcomes unchanged; staff registry retains10identities while4unassigned B2 metadata arrays become empty. This is worker-reported focused evidence, not a full gate.

Review found the staff UI incorrectly called a caller-filtered empty list unassigned. Nonowners now see neutral Arabic text meaning no branches visible within their permissions. Owner complete-list label remains unchanged. No hidden-membership count or flag is added. Edit help explains partial visibility; unchanged branch selections are omitted from update payloads rather than submitting the displayed subset as a replacement. Explicit branch changes still go through existing server checks. Effective0055update function checks every requested branch and every removed old branch with fn_require_branch, so a hidden branch cannot silently be removed or reassigned through the registry. Nonbranch changes involving hidden memberships may still be refused by the existing server gate; this restriction was not loosened.

Demo staff-list aggregation now mirrors caller-visible branch filtering. Verification:5helper unit tests,2selected demo regression tests (DS09,MX06;125other tests skipped), existing manager staff UI flow and new hidden-metadata UI scenario pass. New UI scenario uses a fresh browser context and explicitly restricts the seeded manager to one branch. First attempt lacked that fixture restriction and failed setup, then corrected; not an application failure. Typecheck and demo build pass. Screenshot inspected at1321x870: neutral badge readable, no edit/activation controls granted, registry and existing permitted sign-out controls preserved. No live messages were sent.
