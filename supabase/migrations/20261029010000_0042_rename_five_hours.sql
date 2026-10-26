-- =====================================================================
-- 0042 — The project is called «فايف اورز» (Five Hours), no longer «منازل الراحة» (Comfort Homes).
--        The owner's request before the final approval (26 Oct 2026). Renames the organisation that still carries the
--        old name; any other name an owner has set is left alone. The reception assistant and WhatsApp read the name
--        from this row. One audit row records the change.
-- =====================================================================
do $$
declare o record;
begin
  for o in select id, name_ar, name_en from organizations where name_ar = 'منازل الراحة' or name_en = 'Comfort Homes' loop
    update organizations set name_ar = case when name_ar = 'منازل الراحة' then 'فايف اورز' else name_ar end,
                             name_en = case when name_en = 'Comfort Homes' then 'Five Hours' else name_en end
     where id = o.id;
    insert into audit_events(organization_id, branch_id, actor_id, action, entity_type, entity_id, details)
    values (o.id, null, null, 'organization.updated', 'organization', o.id,
            jsonb_build_object('before', jsonb_build_object('name_ar', o.name_ar, 'name_en', o.name_en),
                               'after', jsonb_build_object('name_ar', 'فايف اورز', 'name_en', 'Five Hours'),
                               'reason', 'تغيير اسم المشروع بطلب المالك'));
  end loop;
end $$;
