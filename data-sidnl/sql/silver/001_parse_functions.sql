-- =============================================================================
-- File:    silver/001_parse_functions.sql
-- Purpose: THE PARSER. Pure, immutable SQL functions that turn messy bronze text
--          into typed silver attributes. No table access except brand_matches().
--          Tested by silver/tests/test_parse_functions.sql.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- norm_key: canonical text key.  "Mr. Munchies" / "MR.MUNCHIES" / "mr-munchies" -> 'mr munchies'
-- ---------------------------------------------------------------------------
create or replace function silver.norm_key(p_text text)
returns text language sql immutable parallel safe as $$
    select nullif(
        btrim(regexp_replace(
            regexp_replace(
                lower(replace(replace(replace(coalesce(p_text, ''), '&', ' and '), '''', ''), '’', '')),
                '[^a-z0-9]+', ' ', 'g'),
            '\s+', ' ', 'g')),
        '')
$$;

create or replace function silver.re_escape(p_text text)
returns text language sql immutable parallel safe as $$
    select regexp_replace(coalesce(p_text, ''), '([.\\^$*+?()\[\]{}|-])', '\\\1', 'g')
$$;

-- ---------------------------------------------------------------------------
-- brand_matches: does a raw bronze brand string belong to a tracked brand?
-- Compares space-less normalised keys against brand_key, brand_name, aliases.
-- ---------------------------------------------------------------------------
create or replace function silver.brand_matches(p_brand_key text, p_raw text)
returns boolean language sql stable parallel safe as $$
    select p_raw is not null
       and exists (
            select 1
            from silver.brand_scope b
            where b.brand_key = p_brand_key
              and replace(silver.norm_key(p_raw), ' ', '') = any (
                    select replace(silver.norm_key(a), ' ', '')
                    from unnest(array[b.brand_key, b.brand_name] || b.raw_brand_aliases) a))
$$;

-- ---------------------------------------------------------------------------
-- parse_pack: '270 g' | '1 pc (38.5 g)' | '6 x 330 ml' | '1 L' | '2 kg'
--   -> size_value (in BASE unit g / ml / pc), size_unit, pack_count
-- ---------------------------------------------------------------------------
do $$ begin
    create type silver.pack_t as (size_value numeric, size_unit text, pack_count int);
exception when duplicate_object then null; end $$;

create or replace function silver.parse_pack(p_pack text)
returns silver.pack_t language plpgsql immutable parallel safe as $$
declare
    t     text;
    m     text[];
    v     numeric;
    u     text;
    cnt   int := 1;
begin
    if p_pack is null or btrim(p_pack) = '' then
        return (null::numeric, null::text, 1)::silver.pack_t;
    end if;

    t := lower(btrim(p_pack));
    -- NB: in Postgres regex \y is the word boundary (\b is BACKSPACE).
    t := regexp_replace(t, '(\d),(\d{3})\y', '\1\2', 'g');                 -- 1,000 -> 1000
    t := regexp_replace(t, '(\d),(\d{1,2})\y', '\1.\2', 'g');              -- 0,33  -> 0.33
    t := regexp_replace(t, '\m(litres?|liters?|ltrs?|ltr)\M', 'l', 'g');
    t := regexp_replace(t, '\m(millilit(?:re|er)s?)\M', 'ml', 'g');
    t := regexp_replace(t, '\m(grams?|gms?|gm)\M', 'g', 'g');
    t := regexp_replace(t, '\m(kgs?|kilograms?)\M', 'kg', 'g');

    -- multi-pack:  6 x 330 ml
    m := regexp_match(t, '(\d+)\s*[x×*]\s*(\d+(?:\.\d+)?)\s*(kg|g|ml|l)\M');
    if m is not null then
        cnt := m[1]::int;  v := m[2]::numeric;  u := m[3];
    else
        -- single measure:  270 g  /  1 pc (38.5 g)  -> first measurable token
        m := regexp_match(t, '(\d+(?:\.\d+)?)\s*(kg|g|ml|l)\M');
        if m is not null then
            v := m[1]::numeric;  u := m[2];
        end if;
        -- count of pieces:  1 pc, 6 pcs, 2 units, pack of 4
        m := regexp_match(t, '(\d+)\s*(?:pcs?|pieces?|units?|n)\M');
        if m is not null then cnt := m[1]::int;
        else
            m := regexp_match(t, 'pack of\s*(\d+)');
            if m is not null then cnt := m[1]::int; end if;
        end if;
    end if;

    if u is null then                              -- e.g. '1 N' / '2 pcs' : count only
        return (case when cnt is not null then cnt::numeric end, 'pc', coalesce(cnt, 1))::silver.pack_t;
    end if;

    if u = 'kg' then v := v * 1000; u := 'g';
    elsif u = 'l' then v := v * 1000; u := 'ml';
    end if;

    return (v, u, greatest(coalesce(cnt, 1), 1))::silver.pack_t;
end $$;

-- ---------------------------------------------------------------------------
-- parse_variant: name minus brand, product type, (parentheses) and pack text.
--   'Mr. Munchies Cheese Chilli Samosa (Frozen)' + brand + 'Samosa' -> 'Cheese Chilli'
-- ---------------------------------------------------------------------------
create or replace function silver.parse_variant(p_name text, p_brand text, p_ptype text)
returns text language plpgsql immutable parallel safe as $$
declare v text := coalesce(p_name, '');
begin
    v := regexp_replace(v, '\([^)]*\)', ' ', 'g');
    if p_brand is not null and btrim(p_brand) <> '' then
        v := regexp_replace(v, '^\s*' || silver.re_escape(btrim(p_brand)) || '\s*', ' ', 'i');
    end if;
    if p_ptype is not null and btrim(p_ptype) <> '' then
        v := regexp_replace(v, silver.re_escape(btrim(p_ptype)), ' ', 'i');
    end if;
    v := regexp_replace(v, '\m\d+(?:\.\d+)?\s*(?:kg|gms?|g|ml|ltr|l|pcs?)\M', ' ', 'gi');
    v := btrim(regexp_replace(v, '\s+', ' ', 'g'));
    return nullif(v, '');
end $$;

-- ---------------------------------------------------------------------------
-- Stock state mapping.  Raw: in_stock | out_of_stock | not_listed | anything else
-- ---------------------------------------------------------------------------
create or replace function silver.map_stock_status(p_state text)
returns text language sql immutable parallel safe as $$
    select case lower(btrim(coalesce(p_state, '')))
             when 'in_stock'     then 'in_stock'
             when 'out_of_stock' then 'out_of_stock'
             when 'not_listed'   then 'not_listed'
             else 'unknown' end
$$;

-- ---------------------------------------------------------------------------
-- reading_dq: data-quality flags for ONE reading.
--   invalid flags  -> row kept but excluded from every metric
--   suspect flags  -> row kept, excluded from gold (which filters 'valid')
--   info_* flags   -> expected situations, status stays 'valid'
-- ---------------------------------------------------------------------------
create or replace function silver.reading_dq(
    p_has_product boolean, p_has_store boolean, p_observed timestamptz, p_status text,
    p_inventory int, p_price numeric, p_mrp numeric)
returns text[] language sql immutable parallel safe as $$
    select coalesce(array_remove(array[
        case when not coalesce(p_has_product, false) then 'no_product' end,
        case when not coalesce(p_has_store,   false) then 'no_store' end,
        case when p_observed is null or p_observed < timestamptz '2020-01-01'
                  or p_observed > now() + interval '1 day' then 'bad_timestamp' end,
        case when p_status = 'unknown' then 'unknown_state' end,
        case when p_inventory < 0 then 'negative_inventory' end,
        case when p_price < 0 then 'negative_price' end,
        case when p_price > p_mrp and p_mrp > 0 then 'sp_gt_mrp' end,
        case when p_price is not null and coalesce(p_mrp, 0) <= 0 then 'mrp_missing' end,
        case when p_status = 'out_of_stock' and coalesce(p_inventory, 0) > 0 then 'oos_with_inventory' end,
        case when p_status = 'in_stock' and p_price is null then 'price_missing_in_stock' end,
        case when p_status = 'out_of_stock' and p_price is null then 'info_price_missing_oos' end,
        case when p_status = 'not_listed' then 'info_not_listed' end
    ], null), '{}'::text[])
$$;

create or replace function silver.dq_status(p_flags text[])
returns text language sql immutable parallel safe as $$
    select case
        when p_flags && array['no_product','no_store','bad_timestamp','unknown_state',
                              'negative_inventory','negative_price'] then 'invalid'
        when p_flags && array['sp_gt_mrp','mrp_missing','oos_with_inventory',
                              'price_missing_in_stock'] then 'suspect'
        else 'valid' end
$$;

comment on function silver.parse_pack(text)    is 'Pack text -> (size_value in base g/ml/pc, size_unit, pack_count).';
comment on function silver.parse_variant(text,text,text) is 'Product name minus brand / product type / pack text.';
comment on function silver.reading_dq(boolean,boolean,timestamptz,text,int,numeric,numeric) is 'DQ flags for one reading; see silver.dq_status().';
