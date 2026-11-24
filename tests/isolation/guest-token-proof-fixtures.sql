-- Optional standalone synthetic setup; load inside the SAME transaction as guest-token-proof.sql.
\set ON_ERROR_STOP on
insert into organizations(id,name_ar,guest_slug) values
 ('e1810000-0000-0000-0000-000000000001','Guest A','iso-gate-a'),('e1810000-0000-0000-0000-000000000002','Guest B','iso-gate-b');
insert into branches(id,organization_id,name_ar) values
 ('e1810000-0000-0000-0000-000000000011','e1810000-0000-0000-0000-000000000001','Guest A1'),('e1810000-0000-0000-0000-000000000012','e1810000-0000-0000-0000-000000000002','Guest B1');
insert into reservations(id,organization_id,branch_id,check_in,check_out) values
 ('e1810000-0000-0000-0000-000000000101','e1810000-0000-0000-0000-000000000001','e1810000-0000-0000-0000-000000000011',current_date,current_date+2),
 ('e1810000-0000-0000-0000-000000000102','e1810000-0000-0000-0000-000000000002','e1810000-0000-0000-0000-000000000012',current_date,current_date+2);
insert into registration_sessions(reservation_id,token,expires_at) values
 ('e1810000-0000-0000-0000-000000000101','SYNTHETIC-GUEST-A',now()+interval '1 hour'),('e1810000-0000-0000-0000-000000000102','SYNTHETIC-GUEST-B',now()+interval '1 hour');
