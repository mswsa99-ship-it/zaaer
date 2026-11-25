-- Individual endpoint view grants; preserve legacy capability, branch and money boundaries.
begin;
do $$ declare d text; n text;
begin
  d := pg_get_functiondef('public.fn_admin_products()'::regprocedure);
  n := replace(d, 'perform fn_require_cap(''definitions'');',
    'if fn_user_access_mode() = ''individual'' then perform fn_require_user_page(''/admin/products'', ''view''); else perform fn_require_cap(''definitions''); end if;');
  if n = d then raise exception 'fn_admin_products guard text not found'; end if;
  execute n;
  d := pg_get_functiondef('public.fn_staff_product_orders(uuid,text,integer)'::regprocedure);
  n := replace(d, 'perform fn_require_cap(''voucher.receipt'');',
    'if fn_user_access_mode() = ''individual'' then perform fn_require_user_page(''/staff/orders'', ''view''); if not fn_sees_money() then raise exception ''FORBIDDEN: money visibility'' using errcode = ''42501''; end if; else perform fn_require_cap(''voucher.receipt''); end if;');
  if n = d then raise exception 'fn_staff_product_orders guard text not found'; end if;
  execute n;
end $$;

commit;
