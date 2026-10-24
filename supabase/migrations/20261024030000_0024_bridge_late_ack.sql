-- =====================================================================
-- 0024 — a late confirmation from the reception computer still counts.
--
-- A staff reply picked by the program and not confirmed within 5 minutes is reported as failed ("no_ack"), so the
-- inbox never shows a reply as sent that may not have been typed. When the program DID type it but could not reach
-- the server for a while, it keeps the confirmation and sends it later: that late "sent" now turns the reply into
-- "sent" (and clears the error), so staff are not led to send it a second time. A late failure changes nothing, and a
-- reply that failed for another reason stays failed.
-- =====================================================================

create or replace function fn_wa_bridge_ack(p_branch uuid, p_id uuid, p_ok boolean, p_wa_id text default null, p_error text default null) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare v_msg uuid;
begin
  update whatsapp_outbox set status = case when p_ok then 'sent' else 'failed' end, wa_id = left(p_wa_id, 200),
         error = case when p_ok then null else left(coalesce(nullif(btrim(p_error), ''), 'send_failed'), 200) end, finished_at = now()
   where id = p_id and branch_id = p_branch
     and (status = 'sending' or (coalesce(p_ok, false) and status = 'failed' and error = 'no_ack'))
  returning message_id into v_msg;
  if v_msg is null then return false; end if;
  update conversation_messages set meta = case
           when p_ok then (coalesce(meta, '{}'::jsonb) - 'error') || jsonb_build_object('delivery', 'sent')
           else coalesce(meta, '{}'::jsonb) || jsonb_build_object('delivery', 'failed', 'error', left(coalesce(nullif(btrim(p_error), ''), 'send_failed'), 200)) end
   where id = v_msg;
  return true;
end $$;
revoke all on function fn_wa_bridge_ack(uuid, uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function fn_wa_bridge_ack(uuid, uuid, boolean, text, text) to service_role;
