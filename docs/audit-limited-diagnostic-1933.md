# Limited audit direct-read inconsistency, diagnostic only

PG16.6 iso_candidate_reads1917 through0121, synthetic supervisor hotelA branch1, one synthetic business audit with hidden literal marker. Authenticated SELECT privilege on table and details column, mgmt_audit_read RLS current. Diagnostic creates no Auth rows, no policy/grant changes, all business/individual fixture changes rollback.

Three contrasts: legacy supervisor; enabledindividual with audit page+canonical reservations view; enabledindividual audit page only. All fn_can(audit.log)=true and fn_cap_full=false. RPC fn_audit_list returned exactly targeted row with details null. Direct details SELECT returned hidden marker in legacy and both-page individual, no row in audit-only because current RLS also gates reservations view. Whole-public no-write around reads.

This establishes an existing limited RPC/direct table inconsistency under unchanged legacy full_roles and under currently implemented individual logic. It does not decide approved individual full/limited intent. No fix selected. Column masking cannot be achieved with a row policy alone; possible fixes require reviewing direct UI consumers/column grants and business/output contract. No acceptance PASS credit. Protected endpoints unexecuted.
