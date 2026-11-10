-- silver_056_parse_pack_counts
-- Fixes silver.parse_pack so size / pack_count say exactly what the bronze pack string says
-- (docs/silver/CANONICAL_MAPPING_AUDIT_2026-11-10.md, defect D1):
--   * a multiplier AFTER the size ("100 g X 2", "500 ml X 4") was dropped -> pack_count 1
--   * piece counts: "10 pcs" was size 10 x pack 10 (total 100); "30 tabs", "60 capsules", "4 packs",
--     "30 sheets" lost their number (1 pc); "2 x 1 pc" -> 1; "2 x 10 pcs" -> total 100
--   * "40U x 25g" -> 25 g (count lost)
--   * "7 pcs + 102 g" -> 7 x 102 g (a count multiplied into a weight the raw text does not state)
-- Convention after this fix: size_value = content of ONE pack (g / ml / pc), pack_count = number of packs,
-- total_content (generated) = size_value * pack_count.
-- Then re-derives size/unit/pack for existing silver.dim_product rows from their own pack_raw (the exact bronze
-- string) and queues one forced pipeline job, so the normal pipeline syncs canonical attributes, resequences SI ids
-- with its own logic, runs the quality gate and refreshes gold. No bronze table is read or written here.

insert into ops.function_backup (fn, tag, definition)
select f, 'pre_silver_056', pg_get_functiondef(f::regprocedure)
from unnest(array['silver.parse_pack(text)', 'silver.selftest_parser()']) f;

create or replace function silver.parse_pack(p_pack text)
 returns silver.pack_t
 language plpgsql
 immutable parallel safe
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare
    t text; m text[]; v numeric; u text; cnt int := 1;
    parts text[]; pt text; pm text[]; c int; vv numeric; uu text;
    u0 text; v0 numeric; tot numeric := 0; tcnt int := 0; same boolean := true; ok boolean := true;
begin
    if p_pack is null or btrim(p_pack) = '' then
        return (null::numeric, null::text, 1)::silver.pack_t;
    end if;

    t := lower(btrim(p_pack));
    t := regexp_replace(t, '(\d),(\d{3})\y', '\1\2', 'g');
    t := regexp_replace(t, '(\d),(\d{1,2})\y', '\1.\2', 'g');
    t := regexp_replace(t, '\m(litres?|liters?|ltrs?|ltr)\M', 'l', 'g');
    t := regexp_replace(t, '\m(millilit(?:re|er)s?)\M', 'ml', 'g');
    t := regexp_replace(t, '\m(grams?|gms?|gm)\M', 'g', 'g');
    t := regexp_replace(t, '\m(kgs?|kilograms?)\M', 'kg', 'g');
    -- every word that counts items (not content) becomes "pc"
    t := regexp_replace(t, '(\d)\s*(pcs?|pieces?|units?|nos?|n|u|tabs?|tablets?|capsules?|caps|strips?|sheets?|sachets?|packs?|sets?)\M',
                        '\1 pc', 'g');

    -- "a + b + c": same unit and same size -> size x count; same unit, different sizes -> total; mixed units -> below
    if t ~ '\d\s*(?:kg|g|ml|l|pc)?\s*\+\s*\d' then
        parts := regexp_split_to_array(t, '\s*\+\s*');
        foreach pt in array parts loop
            pm := regexp_match(btrim(pt), '^(?:(\d+)\s*[x×*]\s*)?(\d+(?:\.\d+)?)\s*(kg|g|ml|l|pc)\M');
            if pm is null then ok := false; exit; end if;
            c := coalesce(pm[1]::int, 1); vv := pm[2]::numeric; uu := pm[3];
            if uu = 'kg' then vv := vv * 1000; uu := 'g'; elsif uu = 'l' then vv := vv * 1000; uu := 'ml'; end if;
            if u0 is null then u0 := uu; v0 := vv;
            elsif u0 <> uu then ok := false; exit; end if;
            if vv <> v0 then same := false; end if;
            tot := tot + c * vv; tcnt := tcnt + c;
        end loop;
        if ok and u0 is not null then
            if same then return (v0, u0, tcnt)::silver.pack_t;
            else return (tot, u0, 1)::silver.pack_t; end if;
        end if;
    end if;

    -- count BEFORE the size: "6 x 330 ml", "2 x 10 pc", "40 pc x 25 g", "1 pack (10 x 14 g)"
    m := regexp_match(t, '(\d+)\s*(?:pc\s*)?[x×*]\s*(\d+(?:\.\d+)?)\s*(kg|g|ml|l|pc)\M');
    if m is not null then
        cnt := m[1]::int;  v := m[2]::numeric;  u := m[3];
    else
        -- count AFTER the size at the end of the string: "100 g x 2", "500 ml x 4"
        m := regexp_match(t, '(\d+(?:\.\d+)?)\s*(kg|g|ml|l|pc)\s*[x×*]\s*(\d+)\s*\)?\s*$');
        if m is not null then
            v := m[1]::numeric;  u := m[2];  cnt := m[3]::int;
        else
            m := regexp_match(t, '(\d+(?:\.\d+)?)\s*(kg|g|ml|l)\M');
            if m is not null then
                v := m[1]::numeric;  u := m[2];
                if t !~ '\+' then
                    -- "2 pc (500 g)" keeps its count; a mixed list such as "7 pcs + 102 g" does not multiply
                    m := regexp_match(t, '(\d+)\s*pc\M');
                    if m is not null then cnt := m[1]::int;
                    else
                        m := regexp_match(t, 'pack of\s*(\d+)');
                        if m is not null then cnt := m[1]::int; end if;
                    end if;
                end if;
            else
                -- count only: "10 pcs" = one pack of 10 pieces
                m := regexp_match(t, '(\d+(?:\.\d+)?)\s*pc\M');
                if m is null then m := regexp_match(t, 'pack of\s*(\d+(?:\.\d+)?)'); end if;
                if m is not null then
                    return (m[1]::numeric, 'pc', 1)::silver.pack_t;
                end if;
                return (1::numeric, 'pc', 1)::silver.pack_t;
            end if;
        end if;
    end if;

    if u = 'kg' then v := v * 1000; u := 'g';
    elsif u = 'l' then v := v * 1000; u := 'ml';
    end if;

    return (v, u, greatest(coalesce(cnt, 1), 1))::silver.pack_t;
end $function$;

create or replace function silver.selftest_parser()
 returns text
 language plpgsql
 stable
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare
    p silver.pack_t;
begin
    assert silver.norm_key('Mr. Munchies')   = 'mr munchies',  'norm_key dotted';
    assert silver.norm_key('MR.MUNCHIES')    = 'mr munchies',  'norm_key upper';
    assert silver.norm_key('Mr.Munchies')    = 'mr munchies',  'norm_key no space';
    assert silver.norm_key('Lay''s')         = 'lays',         'norm_key apostrophe';
    assert silver.norm_key('Crunch & Munch') = 'crunch and munch', 'norm_key ampersand';
    assert silver.norm_key('   ')            is null,          'norm_key blank';
    assert silver.norm_key(null)             is null,          'norm_key null';

    assert silver.brand_matches('mr munchies', 'Mr. Munchies'),     'brand exact';
    assert silver.brand_matches('mr munchies', 'MrMunchies'),       'brand compact';
    assert silver.brand_matches('mr munchies', 'mr-munchies'),      'brand hyphen';
    assert not silver.brand_matches('mr munchies', 'Crunch & Munch'), 'brand must not substring-match';
    assert not silver.brand_matches('mr munchies', 'Nestle Munch'),   'brand must not substring-match 2';
    assert not silver.brand_matches('mr munchies', null),             'brand null';

    p := silver.parse_pack('270 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (270, 'g', 1), 'pack 270 g';
    p := silver.parse_pack('1 pc (38.5 g)');
    assert (p.size_value, p.size_unit, p.pack_count) = (38.5, 'g', 1), 'pack 1 pc (38.5 g)';
    p := silver.parse_pack('330 ml');
    assert (p.size_value, p.size_unit, p.pack_count) = (330, 'ml', 1), 'pack 330 ml';
    p := silver.parse_pack('1 L');
    assert (p.size_value, p.size_unit, p.pack_count) = (1000, 'ml', 1), 'pack 1 L -> 1000 ml';
    p := silver.parse_pack('1.5 Ltr');
    assert (p.size_value, p.size_unit, p.pack_count) = (1500, 'ml', 1), 'pack 1.5 Ltr';
    p := silver.parse_pack('2 kg');
    assert (p.size_value, p.size_unit, p.pack_count) = (2000, 'g', 1), 'pack 2 kg';
    p := silver.parse_pack('6 x 330 ml');
    assert (p.size_value, p.size_unit, p.pack_count) = (330, 'ml', 6), 'pack 6 x 330 ml';
    p := silver.parse_pack('0,5 kg');
    assert (p.size_value, p.size_unit, p.pack_count) = (500, 'g', 1), 'pack decimal comma';
    p := silver.parse_pack('1 N');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 1), 'pack 1 N';
    p := silver.parse_pack('3 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (3, 'pc', 1), 'pack 3 pcs = one pack of 3 pieces';
    p := silver.parse_pack(null);
    assert p.size_value is null and p.pack_count = 1, 'pack null';
    p := silver.parse_pack('assorted');
    assert p.size_value is null or p.size_unit = 'pc', 'pack junk does not crash';

    -- silver_056: exact pack strings seen in bronze public.platform_products
    p := silver.parse_pack('100 g X 2');
    assert (p.size_value, p.size_unit, p.pack_count) = (100, 'g', 2), 'pack 100 g X 2';
    p := silver.parse_pack('500 ml X 4');
    assert (p.size_value, p.size_unit, p.pack_count) = (500, 'ml', 4), 'pack 500 ml X 4';
    p := silver.parse_pack('2 x 1 pc');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 2), 'pack 2 x 1 pc';
    p := silver.parse_pack('2 x 10 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'pc', 2), 'pack 2 x 10 pcs';
    p := silver.parse_pack('10 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'pc', 1), 'pack 10 pcs';
    p := silver.parse_pack('30 tabs');
    assert (p.size_value, p.size_unit, p.pack_count) = (30, 'pc', 1), 'pack 30 tabs';
    p := silver.parse_pack('60 capsules');
    assert (p.size_value, p.size_unit, p.pack_count) = (60, 'pc', 1), 'pack 60 capsules';
    p := silver.parse_pack('4 packs');
    assert (p.size_value, p.size_unit, p.pack_count) = (4, 'pc', 1), 'pack 4 packs';
    p := silver.parse_pack('1 unit + 1 unit');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 2), 'pack 1 unit + 1 unit';
    p := silver.parse_pack('40U x 25g');
    assert (p.size_value, p.size_unit, p.pack_count) = (25, 'g', 40), 'pack 40U x 25g';
    p := silver.parse_pack('7 pcs + 102 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (102, 'g', 1), 'pack 7 pcs + 102 g does not multiply';
    p := silver.parse_pack('1 pack (1.25 kg)');
    assert (p.size_value, p.size_unit, p.pack_count) = (1250, 'g', 1), 'pack 1 pack (1.25 kg)';
    p := silver.parse_pack('1 pack (5 X 10 ml)');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'ml', 5), 'pack 1 pack (5 X 10 ml)';
    p := silver.parse_pack('2 x 45 g + 35 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (125, 'g', 1), 'pack 2 x 45 g + 35 g';
    p := silver.parse_pack('100 g + 100 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (100, 'g', 2), 'pack 100 g + 100 g';

    assert silver.parse_variant('Mr. Munchies Cheese Chilli Samosa (Frozen)', 'Mr. Munchies', 'Samosa') = 'Cheese Chilli', 'variant samosa';
    assert silver.parse_variant('Mr. Munchies Veg Spring Roll (Frozen)',      'Mr. Munchies', 'Spring Roll') = 'Veg', 'variant roll';
    assert silver.parse_variant('Mr. Munchies Spicy Frozen Paneer Bites',     'Mr. Munchies', 'Frozen Paneer Bites') = 'Spicy', 'variant paneer';
    assert silver.parse_variant('Mr. Munchies Lasooni Soya Chaap',            'Mr. Munchies', 'Soya Chaap') = 'Lasooni', 'variant chaap';
    assert silver.parse_variant('Mr. Munchies Samosa',                        'Mr. Munchies', 'Samosa') is null, 'variant empty -> null';

    assert silver.map_stock_status('in_stock')     = 'in_stock',     'state in';
    assert silver.map_stock_status('OUT_OF_STOCK') = 'out_of_stock', 'state out';
    assert silver.map_stock_status('not_listed')   = 'not_listed',   'state nl';
    assert silver.map_stock_status('weird')        = 'unknown',      'state unknown';
    assert silver.map_stock_status(null)           = 'unknown',      'state null';

    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,179,179)) = 'valid',   'dq clean';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'out_of_stock',0,null,null)) = 'valid', 'dq oos without price is valid';
    assert silver.dq_status(silver.reading_dq(true,false,now(),'in_stock',3,179,179)) = 'invalid', 'dq no store';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',-1,179,179)) = 'invalid', 'dq negative inv';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,200,179)) = 'suspect', 'dq sp > mrp';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,179,null)) = 'suspect', 'dq mrp missing';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'out_of_stock',4,179,179)) = 'suspect', 'dq oos with inventory';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,null,null)) = 'suspect', 'dq in stock no price';
    assert silver.dq_status(silver.reading_dq(true,true,now() + interval '30 days','in_stock',3,179,179)) = 'invalid', 'dq future ts';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'unknown',3,179,179)) = 'invalid', 'dq unknown state';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'not_listed',null,null,null)) = 'valid', 'dq not_listed valid';
    return 'all parser tests passed';
end
$function$;

-- the migration aborts here if any parser assertion fails
select silver.selftest_parser();

update silver.dim_product d
   set size_value = pk.size_value, size_unit = pk.size_unit, pack_count = pk.pack_count
  from silver.dim_product d2 cross join lateral silver.parse_pack(d2.pack_raw) pk
 where d2.product_key = d.product_key
   and (d.size_value, d.size_unit, d.pack_count) is distinct from (pk.size_value, pk.size_unit, pk.pack_count);

-- normal pipeline does the rest (canonical attrs, SI resequence, quality gate, gold)
insert into ops.pipeline_job (job_type, trigger, force, status) values ('regular', 'silver_056', true, 'queued');
