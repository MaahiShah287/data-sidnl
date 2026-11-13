-- silver_076: second part of the platform_listings drift (silver_075 fixed the brand column).
-- public.platform_listings lost name, pack_size, image_url (and brand, details): the scraper now keeps them once per
-- platform product in public.platform_products (name, pack, image_url). silver.refresh_brand built its _listings
-- temp table from pl.name / pl.pack_size / pl.image_url, so every run failed at step refresh_brand:<brand> with
-- "column pl.name does not exist" right after silver_075 let the discover stage pass (run 1669, 2026-11-13).
-- _listings now takes them from platform_products (unique per platform + external_id; all 28 listings match one);
-- the brand rule and everything downstream of _listings are unchanged.

do $mig$
declare v_def text; v_new text;
begin
    v_def := pg_get_functiondef('silver.refresh_brand(text,boolean)'::regprocedure);
    v_new := v_def;

    v_new := replace(v_new, 'coalesce(pl.name, p.name)', 'coalesce(pp.name, p.name)');
    if v_new = v_def then raise exception 'silver_076: coalesce(pl.name, p.name) not found'; end if;
    v_def := v_new;

    v_new := replace(v_new, 'pl.pack_size,', 'pp.pack                                 as pack_size,');
    if v_new = v_def then raise exception 'silver_076: pl.pack_size not found'; end if;
    v_def := v_new;

    v_new := replace(v_new, 'coalesce(pl.image_url, p.image_url)', 'pp.image_url');
    if v_new = v_def then raise exception 'silver_076: coalesce(pl.image_url, p.image_url) not found'; end if;
    v_def := v_new;

    v_new := replace(v_new, 'join public.products p on p.id = pl.product_id',
                     E'join public.products p on p.id = pl.product_id\n    left join public.platform_products pp on pp.platform = pl.platform and pp.external_id = pl.external_id');
    if v_new = v_def then raise exception 'silver_076: products join not found'; end if;

    execute v_new;
end
$mig$;
