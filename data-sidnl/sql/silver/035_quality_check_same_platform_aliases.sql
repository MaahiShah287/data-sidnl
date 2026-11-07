-- Applied to Supabase as migration silver_035_quality_check_same_platform_aliases.
-- Two ids of one platform under one SI id is allowed only when they are exact duplicates
-- (same normalised name + pack). Anything else is flagged.
create or replace function silver.quality_checks()
returns table(check_name text, ok boolean, detail text)
language plpgsql stable set search_path = silver, public, extensions, pg_temp as $$
declare v_parser text; v_n bigint;
begin
    v_parser := silver.selftest_parser();
    check_name := 'parser_selftest'; ok := v_parser = 'all parser tests passed'; detail := v_parser; return next;

    for check_name, ok, detail in
        select 'matcher_selftest:' || t.test, t.ok, t.detail from silver.selftest_matcher_pure() t loop
        return next;
    end loop;

    select count(*) into v_n from silver.dim_product p
     where not exists (select 1 from silver.product_xref x where x.product_key = p.product_key);
    check_name := 'every_product_has_si_id'; ok := v_n = 0; detail := v_n || ' products without an SI id'; return next;

    select count(*) into v_n from silver.product_xref x join silver.canonical_product c using (sidnl_id) where not c.is_active;
    check_name := 'xref_points_to_active_si_id'; ok := v_n = 0; detail := v_n || ' products mapped to a retired SI id'; return next;

    select count(*) into v_n from (
        select x.sidnl_id, d.platform from silver.product_xref x join silver.dim_product d using (product_key)
        group by 1, 2
        having count(*) > 1 and count(distinct silver.exact_key(d.product_name, d.pack_raw)) > 1) z;
    check_name := 'same_platform_pairs_are_exact_duplicates'; ok := v_n = 0;
    detail := v_n || ' SI ids hold two same-platform products that are not exact duplicates'; return next;

    select count(*) into v_n from silver.canonical_product c
     where c.is_active and not exists (select 1 from silver.product_xref x where x.sidnl_id = c.sidnl_id);
    check_name := 'no_empty_si_ids'; ok := v_n = 0; detail := v_n || ' active SI ids without any product'; return next;
end $$;
