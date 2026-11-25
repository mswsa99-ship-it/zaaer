# 0122 bounded direct audit column repair

Source consumer src/pages/staff/StaffReservationDetail.tsx409 only direct query selects action,created_at,actor_id with entity_id filter. Admin log uses api.ts1271 fn_audit_list. No other production frontend direct audit query found. Restrict authenticated directSELECT to these4columns, remove anon directSELECT. Existing RLS/page/branch/security rules unchanged. Rich columns remain available via SECURITY DEFINER RPCs under their existing output contracts. No owner/manager fullrole behavior or individual intent decision changed.

Actual PG16.6 valid RED15/34 then GREEN34/0 on reads1917,0122applied. Exactsyntheticauditrow: owner/manager/supervisor legacy+enabledindividualRPCpositive full/masked detail preserved, directtimeline positiveall6, directdetails andwhole-row42501all6, otherhotel empty, anon42501, wholepublicreadsnowrite. Utilityidentity301, individual4224, read592+182+628 regressions green.

Existing reservation history separately DIAGNOSTIC: supervisor legacyandindividual fn_audit_list masks marker, fn_reservation_detail history exposes same marker. This is not closed by0122, and is not treated as approved individual intent or automatically declared forbidden. Needs explicit output/domain decision separate from direct audit permission leak. Fullsecurity/2.11 acceptance remainsINCOMPLETE. Old direct diagnostic expects pre0122 grants and deliberately no longer applies to repairedDB; retain RED provenance, notrerunpassgate.

Only local disposable migration application; no live migration/publication/Auth changes.

Follow-up source grounding19:37: ReservationOperations.tsx154-159 actively renders details.reason and before/after values, embedded StaffReservationDetail357. Exact10:44WhatsApp design proposal and11:05approval recovered; neither defines generic audit full/limited versus reservation-history detail access. Thus this is a concrete output-scope decision, not an unused field cleanup. Do not silently extend0122 to redact reservation history.
