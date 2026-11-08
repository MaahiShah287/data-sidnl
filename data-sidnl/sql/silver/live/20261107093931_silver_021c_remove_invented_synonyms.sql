delete from silver.ref_variant_synonym
 where syn_key in ('chili','chilly','chille','vegetable','vegetables','samosas','samose');

create or replace function silver.selftest_matcher_pure()
returns table (test text, ok boolean, detail text)
language plpgsql set search_path = silver, public, extensions, pg_temp as $$
begin
    test := 'token_set_sim: subset of tokens = 1'; ok := silver.token_set_sim('alpha beta', 'alpha gamma beta') = 1; detail := ''; return next;
    test := 'token_set_sim: unrelated tokens < 0.3'; ok := silver.token_set_sim('alpha beta', 'gamma delta') < 0.3; detail := silver.token_set_sim('alpha beta', 'gamma delta')::text; return next;
    test := 'synonym table: every active synonym rewrites to its canonical token';
    ok := not exists (select 1 from silver.ref_variant_synonym r
                      where r.is_active and silver.canon_tokens(r.syn_key) is distinct from silver.canon_tokens(r.variant));
    detail := ''; return next;
    test := 'SI id format 1/999/1000'; ok := silver.format_sidnl_id(1) = 'SI001' and silver.format_sidnl_id(999) = 'SI999' and silver.format_sidnl_id(1000) = 'SI1000'; detail := ''; return next;
    test := 'SI id normalise'; ok := silver.sidnl_normalize(' si1 ') = 'SI001' and silver.sidnl_normalize('SI0001') = 'SI001' and silver.sidnl_normalize('SI000') is null and silver.sidnl_normalize('xyz') is null; detail := ''; return next;
end $$;