create or replace function silver.selftest_matcher_pure()
returns table (test text, ok boolean, detail text)
language plpgsql set search_path = silver, public, extensions, pg_temp as $$
begin
    test := 'token_set_sim: subset of tokens = 1'; ok := silver.token_set_sim('alpha beta', 'alpha gamma beta') = 1; detail := ''; return next;
    test := 'token_set_sim: unrelated tokens < 0.3'; ok := silver.token_set_sim('alpha beta', 'gamma delta') < 0.3; detail := silver.token_set_sim('alpha beta', 'gamma delta')::text; return next;
    test := 'synonym table: chili and chilli are one token'; ok := silver.canon_tokens('chili') = silver.canon_tokens('chilli'); detail := ''; return next;
    test := 'SI id format 1/999/1000'; ok := silver.format_sidnl_id(1) = 'SI001' and silver.format_sidnl_id(999) = 'SI999' and silver.format_sidnl_id(1000) = 'SI1000'; detail := ''; return next;
    test := 'SI id normalise'; ok := silver.sidnl_normalize(' si1 ') = 'SI001' and silver.sidnl_normalize('SI0001') = 'SI001' and silver.sidnl_normalize('SI000') is null and silver.sidnl_normalize('xyz') is null; detail := ''; return next;
end $$;

create or replace function silver.selftest_matcher()
returns table (test text, ok boolean, detail text)
language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare a silver.match_feat; b silver.match_feat; s silver.score_t; ka int; kx int; ky int;
begin
    -- Uses only rows that already exist in silver.dim_product; nothing is inserted.
    select product_key into ka from silver.dim_product where size_value is not null order by product_key limit 1;
    if ka is null then
        test := 'real-product tests'; ok := true; detail := 'skipped: silver.dim_product has no products with a size yet'; return next;
    else
        a := silver.features_of(ka);
        s := silver.score_pair(a, a);
        test := 'a real product matches itself'; ok := s.score = 1 and s.rule_ok; detail := s::text; return next;

        b := a; b.size_value := a.size_value * 2;
        s := silver.score_pair(a, b);
        test := 'same product at double the size is never the same product'; ok := not s.rule_ok and s.rule_reason = 'SIZE_MISMATCH'; detail := s::text; return next;

        b := a; b.pack_count := coalesce(a.pack_count, 1) + 1;
        s := silver.score_pair(a, b);
        test := 'different pack count is never the same product'; ok := not s.rule_ok and s.rule_reason = 'PACK_COUNT_MISMATCH'; detail := s::text; return next;
    end if;

    select x.product_key, y.product_key into kx, ky
    from silver.dim_product x
    join silver.dim_product y on y.brand_key = x.brand_key and y.size_value = x.size_value
                              and y.size_unit = x.size_unit and y.pack_count = x.pack_count
                              and y.product_key > x.product_key
                              and (silver.features_of(y.product_key)).variant_key is distinct from (silver.features_of(x.product_key)).variant_key
    order by x.product_key, y.product_key limit 1;
    if kx is null then
        test := 'two different real SKUs of equal size must not auto-merge'; ok := true; detail := 'skipped: no such pair in silver.dim_product'; return next;
    else
        s := silver.score_pair(silver.features_of(kx), silver.features_of(ky));
        test := 'two different real SKUs of equal size must not auto-merge (product_key ' || kx || ' vs ' || ky || ')';
        ok := not (s.score >= silver.cfg('th_auto') and s.rule_ok); detail := s::text; return next;
    end if;

    return query select * from silver.selftest_matcher_pure();
end $$;