-- silver_075: bronze drift fix. public.platform_listings.brand no longer exists (scraper schema change,
-- seen 2026-11-13: every silver run died in stage 'discover' with  column "brand" does not exist,
-- 549 failed jobs in 24 h, no gold refresh since 2026-11-11).
-- The brand of a listing is still available through public.products.brand (platform_listings.product_id).
-- Both functions now read the platform_listings brand through to_jsonb(pl) ->> 'brand', which is NULL when the
-- column is absent and the real value if the scraper team ever restores it - so this can never break again.

create or replace function silver.refresh_brand_strings(p_full boolean default false)
 returns integer
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare v_n int := 0; v_c int;
begin
    insert into silver.brand_string_registry (raw_brand)
    select distinct brand::text from public.platform_products where brand is not null
    on conflict do nothing;
    get diagnostics v_c = row_count; v_n := v_n + v_c;

    insert into silver.brand_string_registry (raw_brand)
    select distinct to_jsonb(pl) ->> 'brand' from public.platform_listings pl
     where to_jsonb(pl) ->> 'brand' is not null
    on conflict do nothing;
    get diagnostics v_c = row_count; v_n := v_n + v_c;

    insert into silver.brand_string_registry (raw_brand)
    select distinct brand::text from public.products where brand is not null
    on conflict do nothing;
    get diagnostics v_c = row_count;
    return v_n + v_c;
end $function$;

do $mig$
declare v_def text; v_new text;
begin
    v_def := pg_get_functiondef('silver.refresh_brand(text,boolean)'::regprocedure);
    v_new := replace(v_def, 'coalesce(pl.brand, p.brand)', 'coalesce(to_jsonb(pl) ->> ''brand'', p.brand)');
    if v_new = v_def then
        raise exception 'silver_075: expected text coalesce(pl.brand, p.brand) not found in silver.refresh_brand';
    end if;
    execute v_new;
end
$mig$;
