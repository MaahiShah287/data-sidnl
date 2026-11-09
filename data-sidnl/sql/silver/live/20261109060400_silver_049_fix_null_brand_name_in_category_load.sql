-- A shelf row with a brand key but no raw brand text made refresh_category_products insert a NULL brand_name,
-- which failed every pipeline run since 2026-11-08. Fall back to the brand key.
do $$
declare d text;
begin
  d := pg_get_functiondef('silver.refresh_category_products(bigint,bigint,bigint)'::regprocedure);
  d := replace(d, 'select b.brand_key, b.brand_raw, null, array[b.brand_raw], false, ''category_shelf''',
                  'select b.brand_key, coalesce(b.brand_raw, b.brand_key), null, array[coalesce(b.brand_raw, b.brand_key)], false, ''category_shelf''');
  d := replace(d, 'select b.brand_key, b.brand_raw, null, false from _cp_brand b',
                  'select b.brand_key, coalesce(b.brand_raw, b.brand_key), null, false from _cp_brand b');
  if position('coalesce(b.brand_raw, b.brand_key)' in d) = 0 then raise exception 'patch did not apply'; end if;
  execute d;
end $$;
