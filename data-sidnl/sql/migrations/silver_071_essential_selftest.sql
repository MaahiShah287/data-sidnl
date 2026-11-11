-- silver_071_essential_selftest   (needs silver_069)
-- One self-test suite instead of three overlapping ones.
-- Before: selftest_parser() = 61 one-line asserts that stop at the first failure (and only say its name),
--         selftest_matcher() = 9 tests, quality_checks() re-runs both plus 4 integrity checks, and the Python tests
--         re-ran all three again (~85 executions, many duplicates).
-- After:  silver.selftest() = 35 named behaviours. Every bronze input string of the old asserts is still checked
--         (grouped by behaviour, none dropped); each test reports ALL failing inputs with got/expected; plus three
--         new checks the old suite missed: the failed/incomplete-read rule (data), personal data never read
--         (demo_requests), every sidnl-* cron job active.
-- Kept for callers: selftest_parser() (used by quality_checks -> the quality gate) now returns the same text from
-- the parser + dq part of the suite; selftest_matcher() / selftest_matcher_pure() are unchanged.

CREATE OR REPLACE FUNCTION silver.selftest_pure()
 RETURNS TABLE(suite text, test text, ok boolean, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
with
nk (test, inp, exp) as (values
    ('norm_key: punctuation, case and spacing fold to one key', 'Mr. Munchies', 'mr munchies'),
    ('norm_key: punctuation, case and spacing fold to one key', 'MR.MUNCHIES',  'mr munchies'),
    ('norm_key: punctuation, case and spacing fold to one key', 'Mr.Munchies',  'mr munchies'),
    ('norm_key: apostrophe dropped, & becomes and',            'Lay''s',        'lays'),
    ('norm_key: apostrophe dropped, & becomes and',            'Crunch & Munch','crunch and munch'),
    ('norm_key: blank and NULL give NULL',                     '   ',           null),
    ('norm_key: blank and NULL give NULL',                     null,            null)),
bm (test, inp, exp) as (values
    ('brand_matches: spelling variants of the client brand match', 'Mr. Munchies',   true),
    ('brand_matches: spelling variants of the client brand match', 'MrMunchies',     true),
    ('brand_matches: spelling variants of the client brand match', 'mr-munchies',    true),
    ('brand_matches: never a substring match, never NULL',         'Crunch & Munch', false),
    ('brand_matches: never a substring match, never NULL',         'Nestle Munch',   false),
    ('brand_matches: never a substring match, never NULL',         null,             false)),
pk (test, inp, sv, su, pc) as (values
    ('parse_pack: one size, units converted to g / ml', '270 g',    270::numeric,  'g',  1),
    ('parse_pack: one size, units converted to g / ml', '330 ml',   330,           'ml', 1),
    ('parse_pack: one size, units converted to g / ml', '1 L',      1000,          'ml', 1),
    ('parse_pack: one size, units converted to g / ml', '1.5 Ltr',  1500,          'ml', 1),
    ('parse_pack: one size, units converted to g / ml', '2 kg',     2000,          'g',  1),
    ('parse_pack: one size, units converted to g / ml', '0,5 kg',   500,           'g',  1),
    ('parse_pack: piece words are one pack of N pieces', '1 N',         1,  'pc', 1),
    ('parse_pack: piece words are one pack of N pieces', '3 pcs',       3,  'pc', 1),
    ('parse_pack: piece words are one pack of N pieces', '10 pcs',      10, 'pc', 1),
    ('parse_pack: piece words are one pack of N pieces', '30 tabs',     30, 'pc', 1),
    ('parse_pack: piece words are one pack of N pieces', '60 capsules', 60, 'pc', 1),
    ('parse_pack: piece words are one pack of N pieces', '4 packs',     4,  'pc', 1),
    ('parse_pack: the size in brackets wins',            '1 pc (38.5 g)',      38.5, 'g',  1),
    ('parse_pack: the size in brackets wins',            '1 pack (1.25 kg)',   1250, 'g',  1),
    ('parse_pack: the size in brackets wins',            '1 pack (5 X 10 ml)', 10,   'ml', 5),
    ('parse_pack: multipacks give size x count',         '6 x 330 ml', 330, 'ml', 6),
    ('parse_pack: multipacks give size x count',         '100 g X 2',  100, 'g',  2),
    ('parse_pack: multipacks give size x count',         '500 ml X 4', 500, 'ml', 4),
    ('parse_pack: multipacks give size x count',         '2 x 1 pc',   1,   'pc', 2),
    ('parse_pack: multipacks give size x count',         '2 x 10 pcs', 10,  'pc', 2),
    ('parse_pack: multipacks give size x count',         '40U x 25g',  25,  'g',  40),
    ('parse_pack: plus lists: equal parts count, mixed parts never multiply', '1 unit + 1 unit', 1,   'pc', 2),
    ('parse_pack: plus lists: equal parts count, mixed parts never multiply', '100 g + 100 g',   100, 'g',  2),
    ('parse_pack: plus lists: equal parts count, mixed parts never multiply', '2 x 45 g + 35 g', 125, 'g',  1),
    ('parse_pack: plus lists: equal parts count, mixed parts never multiply', '7 pcs + 102 g',   102, 'g',  1)),
pv (test, name, brand, ptype, exp) as (values
    ('parse_variant: brand, product type and (Frozen) removed', 'Mr. Munchies Cheese Chilli Samosa (Frozen)', 'Mr. Munchies', 'Samosa', 'Cheese Chilli'),
    ('parse_variant: brand, product type and (Frozen) removed', 'Mr. Munchies Veg Spring Roll (Frozen)', 'Mr. Munchies', 'Spring Roll', 'Veg'),
    ('parse_variant: brand, product type and (Frozen) removed', 'Mr. Munchies Spicy Frozen Paneer Bites', 'Mr. Munchies', 'Frozen Paneer Bites', 'Spicy'),
    ('parse_variant: brand, product type and (Frozen) removed', 'Mr. Munchies Lasooni Soya Chaap', 'Mr. Munchies', 'Soya Chaap', 'Lasooni'),
    ('parse_variant: nothing left gives NULL',                  'Mr. Munchies Samosa', 'Mr. Munchies', 'Samosa', null)),
ms (inp, exp) as (values ('in_stock', 'in_stock'), ('OUT_OF_STOCK', 'out_of_stock'), ('not_listed', 'not_listed'),
                         ('weird', 'unknown'), (null, 'unknown')),
-- reading_dq(has_product, has_store, observed, status, inventory, price, mrp) [+ read_flags] -> dq_status
dq (test, lbl, has_store, obs, st, inv, sp, mrp, rs, rc, exp) as (values
    ('dq: clean, out-of-stock-without-price and not_listed readings are valid', 'clean',           true,  now(), 'in_stock',     3,    179::numeric, 179::numeric, null, null::boolean, 'valid'),
    ('dq: clean, out-of-stock-without-price and not_listed readings are valid', 'oos no price',    true,  now(), 'out_of_stock', 0,    null, null, null, null, 'valid'),
    ('dq: clean, out-of-stock-without-price and not_listed readings are valid', 'not_listed',      true,  now(), 'not_listed',   null, null, null, null, null, 'valid'),
    ('dq: rows that metrics must never use are invalid', 'no store',        false, now(), 'in_stock', 3,  179, 179, null, null, 'invalid'),
    ('dq: rows that metrics must never use are invalid', 'negative inv',    true,  now(), 'in_stock', -1, 179, 179, null, null, 'invalid'),
    ('dq: rows that metrics must never use are invalid', 'future ts',       true,  now() + interval '30 days', 'in_stock', 3, 179, 179, null, null, 'invalid'),
    ('dq: rows that metrics must never use are invalid', 'unknown state',   true,  now(), 'unknown',  3,  179, 179, null, null, 'invalid'),
    ('dq: rows that metrics must never use are invalid', 'read failed',     true,  now(), 'in_stock', 3,  179, 179, 'failed', null, 'invalid'),
    ('dq: doubtful rows are suspect (kept, out of metrics)', 'sp > mrp',        true, now(), 'in_stock',     3, 200, 179,  null, null, 'suspect'),
    ('dq: doubtful rows are suspect (kept, out of metrics)', 'mrp missing',     true, now(), 'in_stock',     3, 179, null, null, null, 'suspect'),
    ('dq: doubtful rows are suspect (kept, out of metrics)', 'oos with units',  true, now(), 'out_of_stock', 4, 179, 179,  null, null, 'suspect'),
    ('dq: doubtful rows are suspect (kept, out of metrics)', 'in stock no price', true, now(), 'in_stock',   3, null, null, null, null, 'suspect'),
    ('dq: doubtful rows are suspect (kept, out of metrics)', 'read incomplete', true, now(), 'in_stock',     3, 179, 179,  'ok', false, 'suspect')),
rr (lbl, st, rs, rc, excl, exp) as (values
    ('failed read, oos',          'out_of_stock', 'failed', null::boolean, true,  'unknown'),
    ('incomplete read, oos',      'out_of_stock', 'ok',     false,         true,  'unknown'),
    ('incomplete read, knob off', 'out_of_stock', 'ok',     false,         false, 'out_of_stock'),
    ('complete read, oos',        'out_of_stock', 'ok',     true,          true,  'out_of_stock'),
    ('product check (no snapshot)', 'out_of_stock', null,   null,          true,  'out_of_stock'),
    ('failed read, in stock',     'in_stock',     'failed', null,          true,  'in_stock')),
si (inp, exp) as (values ('12', 12), (' 7 ', 7), ('-3', -3), ('1.5', null::int), ('abc', null), ('', null), (null, null),
                         ('99999999999', null)),
cases as (
    select 'parser' as suite, nk.test, silver.norm_key(nk.inp) is not distinct from nk.exp as ok,
           format('%L -> %L, expected %L', nk.inp, silver.norm_key(nk.inp), nk.exp) as d from nk
    union all
    select 'parser', bm.test, silver.brand_matches('mr munchies', bm.inp) is not distinct from bm.exp,
           format('%L -> %s, expected %s', bm.inp, silver.brand_matches('mr munchies', bm.inp), bm.exp) from bm
    union all
    select 'parser', pk.test, (p.size_value, p.size_unit, p.pack_count) is not distinct from (pk.sv, pk.su, pk.pc),
           format('%L -> %s %s x%s, expected %s %s x%s', pk.inp, p.size_value, p.size_unit, p.pack_count, pk.sv, pk.su, pk.pc)
      from pk cross join lateral silver.parse_pack(pk.inp) p
    union all
    select 'parser', 'parse_pack: NULL and junk never crash',
           (p.size_value is null and p.pack_count = 1) or (j.raw = 'assorted' and (p.size_value is null or p.size_unit = 'pc')),
           format('%L -> %s %s x%s', j.raw, p.size_value, p.size_unit, p.pack_count)
      from (values (null::text), ('assorted')) j (raw) cross join lateral silver.parse_pack(j.raw) p
    union all
    select 'parser', pv.test, silver.parse_variant(pv.name, pv.brand, pv.ptype) is not distinct from pv.exp,
           format('%L -> %L, expected %L', pv.name, silver.parse_variant(pv.name, pv.brand, pv.ptype), pv.exp) from pv
    union all
    select 'parser', 'map_stock_status: known states map, anything else is unknown',
           silver.map_stock_status(ms.inp) = ms.exp, format('%L -> %L, expected %L', ms.inp, silver.map_stock_status(ms.inp), ms.exp) from ms
    union all
    select 'dq', dq.test, silver.dq_status(f.flags) = dq.exp, format('%s -> %s %s, expected %s', dq.lbl, silver.dq_status(f.flags), f.flags, dq.exp)
      from dq cross join lateral (select silver.reading_dq(true, dq.has_store, dq.obs, dq.st, dq.inv, dq.sp, dq.mrp)
                                         || silver.read_flags(dq.rs, dq.rc, true) as flags) f
    union all
    select 'dq', 'read_stock_status: a failed or incomplete read is never out_of_stock',
           silver.read_stock_status(rr.st, rr.rs, rr.rc, rr.excl) = rr.exp,
           format('%s -> %s, expected %s', rr.lbl, silver.read_stock_status(rr.st, rr.rs, rr.rc, rr.excl), rr.exp) from rr
    union all
    select 'dq', 'safe_int: bronze JSON numbers parse, anything else is NULL',
           silver.safe_int(si.inp) is not distinct from si.exp, format('%L -> %s, expected %s', si.inp, silver.safe_int(si.inp), si.exp) from si
    union all
    select 'matcher', 'pure: ' || m.test, m.ok, m.detail from silver.selftest_matcher_pure() m)
select suite, test, bool_and(ok),
       case when bool_and(ok) then count(*) || ' inputs ok'
            else 'FAILED: ' || string_agg(d, '; ') filter (where not ok) end
  from cases
 group by suite, test
 order by suite, test
$function$
;

CREATE OR REPLACE FUNCTION silver.selftest()
 RETURNS TABLE(suite text, test text, ok boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_n bigint;
begin
    return query select * from silver.selftest_pure();

    -- matcher on real products (read only; nothing inserted)
    return query select 'matcher', 'real: ' || m.test, m.ok, m.detail
                   from silver.selftest_matcher() m
                  where not exists (select 1 from silver.selftest_matcher_pure() p where p.test = m.test);

    -- SI-id integrity (the same checks the quality gate blocks on)
    return query select 'integrity', q.check_name, q.ok, q.detail
                   from silver.quality_checks() q
                  where q.check_name <> 'parser_selftest' and q.check_name not like 'matcher_selftest:%';

    -- the read rule on real data: no out_of_stock row may come from a failed or incomplete read
    select (select count(*) from silver.fact_product_reading
             where stock_status = 'out_of_stock'
               and ((read_status is not null and lower(read_status) <> 'ok')
                    or (read_complete is false and coalesce(silver.cfg('exclude_incomplete_reads'), 1) = 1)))
         + (select count(*) from silver.fact_shelf_position
             where stock_status = 'out_of_stock' and shelf_complete is false
               and coalesce(silver.cfg('exclude_incomplete_reads'), 1) = 1)
      into v_n;
    suite := 'integrity'; test := 'no out_of_stock row from a failed or incomplete read'; ok := v_n = 0;
    detail := v_n || ' rows (run silver.backfill_read_flags() if this is the first run after silver_069)'; return next;

    -- personal data: demo_requests is never read by silver, dash, ops or analytics
    select count(*) into v_n from (
        select 1 from pg_depend d
          join pg_rewrite rw on rw.oid = d.objid
          join pg_class v on v.oid = rw.ev_class
          join pg_namespace vn on vn.oid = v.relnamespace
         where d.refobjid = to_regclass('public.demo_requests')
           and vn.nspname in ('silver', 'dash', 'ops', 'analytics')
        union all
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname in ('silver', 'dash', 'ops')
           and p.proname not in ('selftest')
           and p.prosrc ~* 'demo_requests') z;
    suite := 'integrity'; test := 'personal data: nothing in silver / dash / ops / analytics reads demo_requests';
    ok := v_n = 0; detail := v_n || ' objects reference public.demo_requests'; return next;

    select count(*) into v_n from cron.job where jobname like 'sidnl-%' and not active;
    suite := 'automation'; test := 'every sidnl-* cron job is active'; ok := v_n = 0;
    detail := coalesce((select string_agg(jobname, ', ') from cron.job where jobname like 'sidnl-%' and not active), 'all active');
    return next;
end $function$
;

-- compatibility: the quality gate (quality_checks) and old callers keep calling selftest_parser()
CREATE OR REPLACE FUNCTION silver.selftest_parser()
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select coalesce('FAILED: ' || string_agg(t.test || ' -> ' || t.detail, ' | ') filter (where not t.ok),
                    'all parser tests passed')
      from silver.selftest_pure() t
     where t.suite in ('parser', 'dq')
$function$
;

comment on function silver.selftest() is 'The one self-test suite (silver_071): parser, dq, matcher (pure + real products), SI-id integrity, the failed/incomplete-read rule on real data, personal-data guard, cron jobs. Every failing input is listed. Read only.';
comment on function silver.selftest_pure() is 'Data-independent part of silver.selftest() (parser, dq, pure matcher).';
comment on function silver.selftest_parser() is 'Compatibility wrapper used by quality_checks: parser + dq part of silver.selftest_pure().';
