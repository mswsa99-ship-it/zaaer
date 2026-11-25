# Staff assistant (ai-ops): read category to tool matrix

Status of the evidence, not a security claim. Update 22:31: the security reviewer reported (via the coordinator, not re-run by the author) isolated-runtime DB evidence for all 7 read functions: auth-only execute, finance/voucher/context/find/reservation-finance org and branch denials, housekeeping money masking, and seeded rollback positive controls for available rooms and units board (own org/branches only, cross-branch 0, cross-org 0). The staff assistant is READ-ONLY for every role (OPS_READ_ONLY = true).
Every tool runs as the signed-in person (their session, their role, the conversation's branch). The model cannot pick a branch.

| Read category | Tool | Database function it calls | Role/branch gate lives in | Evidence in this repo | Not evidenced |
|---|---|---|---|---|---|
| Day context (arrivals, departures, housekeeping, balances) | get_operations_context | fn_ai_ops_context | the function (money fields stripped for roles without money) | unit: call args + branch scoping; SQL gate files for ops context | per-role runtime probe on the deployed edge function |
| Find a reservation | find_reservation | fn_ai_ops_find_reservation | the function (branch/org) | unit: call args + branch scoping | per-role denial in SQL (not individually listed in this pass) |
| One reservation's money | get_reservation_finance | fn_reservation_finance | the function (money page/role) | unit: call args | per-role denial in SQL (not individually listed in this pass) |
| Free rooms for a period | list_available_rooms | fn_available_rooms | the function | unit: call args | role/branch denial evidence |
| Units board | list_units_board | fn_ops_units_board | the function | unit: call args | role/branch denial evidence |
| Finance report for a period | get_finance_report | fn_reports_finance | the function (finance roles only) | unit DENIAL test (a refusal is thrown, nothing substituted); SQL gate role denials | runtime probe through the deployed edge function |
| Voucher ledger for a period | list_vouchers | fn_voucher_list | the function (finance roles only) | unit DENIAL test; SQL gate role denials | runtime probe through the deployed edge function |

## NO-execution state (what is verified)
- propose_action is filtered out of the declarations, refused by the validator and refused by the executor (unit tests, 17 pass in ops.test.ts).
- The edge function has only the chat and briefing modes. There is no execute mode.
- fn_ai_ops_propose, fn_ai_ops_execute_proposal and fn_ai_ops_reject_proposal are not executable by authenticated (real and isolated, checked with has_function_privilege).
- Real ai-ops is deployed from this source. A request without a token gets 401.

## Not verified (unchanged by the DB-level evidence)
- No model-driven journey (no model key on the isolated project).
- No authenticated HTTP probe by role on a deployed function.
- The "Not evidenced" column's DB-level items are now covered by the security runtime report above; HTTP, model-driven and prompt-injection paths remain untested.
