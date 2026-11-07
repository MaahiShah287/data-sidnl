-- =============================================================================
-- File:    silver/021_matcher.sql
-- Purpose: The canonical matcher, in Postgres (port of sidnl/match.py + normalize.py).
--
--   Check 1  LEXICAL   name token-set similarity (35%) + brand (25%)
--   Check 2  SEMANTIC  size/pack agreement (20%), variant + synonyms (15%), category L1-L3 (5%)
--   Check 3  STRICT    pack count, size > 5%, brand conflict, opposing variant
--   Decision score >= 0.90 and rules pass -> MAPPED to the existing SI id
--            0.75 <= score                -> own new SI id + review suggestion
--            otherwise                    -> NEW_MASTER (new SI id)
--
-- "Semantic" here = the meaning checks of the design report (units, pack sizes,
-- synonyms, taxonomy). No embeddings / RAG involved.
-- Weights are re-normalised over the attributes both products actually have.
-- =============================================================================

do $$ begin
    create type silver.match_feat as (
        name_clean text, brand text, size_value numeric, size_unit text, pack_count int,
        variant_key text, cat_l1 text, cat_l2 text, cat_l3 text);
exception when duplicate_object then null; end $$;

do $$ begin
    create type silver.score_t as (
        score numeric, name_sim numeric, brand_sim numeric, size_sim numeric,
        variant_sim numeric, category_sim numeric, rule_ok boolean, rule_reason text);
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- canon_tokens: text -> distinct tokens, synonyms applied (light -> diet ...)
-- ---------------------------------------------------------------------------
create or replace function silver.canon_tokens(p_text text)
returns text[] language plpgsql stable set search_path = silver, public, extensions, pg_temp as $$
declare t text := silver.norm_key(p_text); r record;
begin
    if t is null then return '{}'::text[]; end if;
    for r in select syn_key, variant from silver.ref_variant_synonym
              where is_active and syn_key <> variant
              order by length(syn_key) desc, syn_key loop
        t := regexp_replace(t, '(^|\s)' || silver.re_escape(r.syn_key) || '(?=\s|$)', '\1' || r.variant, 'g');
    end loop;
    return array(select distinct x from unnest(string_to_array(t, ' ')) x where x <> '' order by x);
end $$;

-- clean_tokens: canon_tokens minus brand words, noise words, digits, 1-char tokens -> sorted string
create or replace function silver.clean_tokens(p_text text, p_brand_key text)
returns text language sql stable set search_path = silver, public, extensions, pg_temp as $$
    select coalesce(string_agg(tok, ' ' order by tok), '')
    from unnest(silver.canon_tokens(p_text)) tok
    where length(tok) > 1
      and tok !~ '^[0-9]+$'
      and tok <> all (string_to_array(coalesce(silver.norm_key(p_brand_key), ''), ' '))
      and not exists (select 1 from silver.ref_noise_word n where n.is_active and n.word = tok)
$$;

-- ---------------------------------------------------------------------------
-- token_set_sim: lexical similarity of two token strings (0..1).
-- Same algorithm as rapidfuzz.token_set_ratio (sorted intersection vs remainders),
-- with trigram similarity as the string ratio.
-- ---------------------------------------------------------------------------
create or replace function silver.token_set_sim(a text, b text)
returns numeric language plpgsql stable set search_path = silver, public, extensions, pg_temp as $$
declare ta text[]; tb text[]; inter text[]; da text[]; db text[]; si text; s1 text; s2 text;
begin
    if coalesce(a, '') = '' and coalesce(b, '') = '' then return 1; end if;
    if coalesce(a, '') = '' or coalesce(b, '') = '' then return 0; end if;
    ta := string_to_array(a, ' '); tb := string_to_array(b, ' ');
    inter := array(select x from unnest(ta) x intersect select y from unnest(tb) y order by 1);
    if cardinality(inter) = 0 then return round(similarity(a, b)::numeric, 4); end if;
    da := array(select x from unnest(ta) x except select y from unnest(tb) y order by 1);
    db := array(select y from unnest(tb) y except select x from unnest(ta) x order by 1);
    if cardinality(da) = 0 or cardinality(db) = 0 then return 1; end if;   -- one side is a subset of the other
    si := array_to_string(inter, ' ');
    s1 := si || ' ' || array_to_string(da, ' ');
    s2 := si || ' ' || array_to_string(db, ' ');
    return round(greatest(similarity(si, s1), similarity(si, s2), similarity(s1, s2))::numeric, 4);
end $$;

-- ---------------------------------------------------------------------------
-- Feature builders
-- ---------------------------------------------------------------------------
create or replace function silver.features_from_text(
    p_name text, p_brand_key text, p_variant text, p_size numeric, p_unit text, p_pack int,
    p_l1 text, p_l2 text, p_l3 text)
returns silver.match_feat language sql stable set search_path = silver, public, extensions, pg_temp as $$
    select row(
        silver.clean_tokens(
            regexp_replace(lower(coalesce(p_name, '')),
                '\m\d+(?:[.,]\d+)?\s*(?:kgs?|gms?|g|ml|ltrs?|l|pcs?|pieces?|units?|packs?)\M', ' ', 'g'),
            p_brand_key),
        silver.norm_key(p_brand_key),
        p_size, p_unit, coalesce(p_pack, 1),
        silver.clean_tokens(p_variant, p_brand_key),
        silver.norm_key(p_l1), silver.norm_key(p_l2), silver.norm_key(p_l3)
    )::silver.match_feat
$$;

create or replace function silver.features_of(p_product_key int)
returns silver.match_feat language sql stable set search_path = silver, public, extensions, pg_temp as $$
    select silver.features_from_text(p.product_name, p.brand_key, p.variant, p.size_value, p.size_unit,
                                     p.pack_count, c.l1_name, c.l2_name, c.l3_name)
    from silver.dim_product p
    left join silver.dim_category c on c.category_key = p.category_key
    where p.product_key = p_product_key
$$;

create or replace function silver.canon_feat(c silver.canonical_product)
returns silver.match_feat language sql immutable set search_path = silver, public, pg_temp as $$
    select row(c.name_clean, c.brand_key, c.size_value, c.size_unit, c.pack_count,
               c.variant_key, c.category_l1, c.category_l2, c.category_l3)::silver.match_feat
$$;

-- ---------------------------------------------------------------------------
-- score_pair: Checks 1-3 for two feature rows.
-- ---------------------------------------------------------------------------
create or replace function silver.score_pair(a silver.match_feat, b silver.match_feat)
returns silver.score_t language plpgsql stable set search_path = silver, public, extensions, pg_temp as $$
declare
    w_name numeric := silver.cfg('w_name');      w_brand numeric := silver.cfg('w_brand');
    w_size numeric := silver.cfg('w_size');      w_var   numeric := silver.cfg('w_variant');
    w_cat  numeric := silver.cfg('w_category');  tol     numeric := silver.cfg('size_tol');
    bmin   numeric := silver.cfg('brand_min_sim'); vmin  numeric := silver.cfg('variant_min_sim');
    pa int := coalesce(a.pack_count, 1);         pb int := coalesce(b.pack_count, 1);
    name_sim numeric; brand_sim numeric := 1; size_sim numeric := 1; var_sim numeric := 1; cat_sim numeric := 1;
    has_brand boolean; has_size boolean; has_var boolean; has_cat boolean;
    size_diff numeric; sum_w numeric; total numeric;
    ok boolean := true; reason text := 'PASSED';
begin
    -- Check 1: lexical -------------------------------------------------------
    name_sim := silver.token_set_sim(a.name_clean, b.name_clean);

    has_brand := coalesce(a.brand, '') <> '' or coalesce(b.brand, '') <> '';
    if not has_brand then brand_sim := 1;
    elsif replace(coalesce(a.brand, ''), ' ', '') = replace(coalesce(b.brand, ''), ' ', '') then brand_sim := 1;
    elsif coalesce(a.brand, '') = '' or coalesce(b.brand, '') = '' then brand_sim := 0.5;
    else
        brand_sim := silver.token_set_sim(a.brand, b.brand);
        if brand_sim < bmin then brand_sim := 0; end if;
    end if;

    -- Check 2: meaning (size / pack, variant + synonyms, taxonomy) ------------
    has_size := a.size_value is not null or b.size_value is not null;
    if pa <> pb then size_sim := 0;
    elsif not has_size then size_sim := 1;
    elsif a.size_value is null or b.size_value is null then size_sim := 0.5;
    elsif a.size_unit is distinct from b.size_unit then size_sim := 0;
    else
        size_diff := abs(a.size_value - b.size_value) / greatest(a.size_value, b.size_value, 0.001);
        size_sim := case when size_diff <= 0.01 then 1 when size_diff <= tol then 0.8 else 0 end;
    end if;

    has_var := coalesce(a.variant_key, '') <> '' or coalesce(b.variant_key, '') <> '';
    if not has_var then var_sim := 1;
    elsif a.variant_key = b.variant_key then var_sim := 1;
    elsif coalesce(a.variant_key, '') = '' or coalesce(b.variant_key, '') = '' then var_sim := 0.5;
    else var_sim := silver.token_set_sim(a.variant_key, b.variant_key);
    end if;

    has_cat := a.cat_l1 is not null or b.cat_l1 is not null;
    if not has_cat then cat_sim := 1;
    elsif a.cat_l1 is null or b.cat_l1 is null then cat_sim := 0.5;     -- one side has no category: neutral
    elsif a.cat_l1 = b.cat_l1 then
        cat_sim := case when a.cat_l2 is not distinct from b.cat_l2
                        then case when a.cat_l3 is not distinct from b.cat_l3 then 1 else 0.9 end
                        else 0.75 end;
    elsif (a.cat_l3 is not null and a.cat_l3 = b.cat_l3) or (a.cat_l2 is not null and a.cat_l2 = b.cat_l2) then cat_sim := 0.85;
    else cat_sim := 0;
    end if;

    -- adaptive weights: only attributes present on either side count ----------
    sum_w := w_name + case when has_brand then w_brand else 0 end + case when has_size then w_size else 0 end
                    + case when has_var then w_var else 0 end + case when has_cat then w_cat else 0 end;
    total := (w_name * name_sim
              + case when has_brand then w_brand * brand_sim else 0 end
              + case when has_size  then w_size  * size_sim  else 0 end
              + case when has_var   then w_var   * var_sim   else 0 end
              + case when has_cat   then w_cat   * cat_sim   else 0 end) / nullif(sum_w, 0);

    -- Check 3: strict safety rules -------------------------------------------
    if pa <> pb then ok := false; reason := 'PACK_COUNT_MISMATCH';
    elsif a.size_value is not null and b.size_value is not null
          and (a.size_unit is distinct from b.size_unit
               or abs(a.size_value - b.size_value) / greatest(a.size_value, b.size_value, 0.001) > tol)
        then ok := false; reason := 'SIZE_MISMATCH';
    elsif coalesce(a.brand, '') <> '' and coalesce(b.brand, '') <> '' and brand_sim < bmin
        then ok := false; reason := 'BRAND_CONFLICT';
    elsif coalesce(a.variant_key, '') <> '' and coalesce(b.variant_key, '') <> ''
          and a.variant_key <> b.variant_key and var_sim < vmin
        then ok := false; reason := 'VARIANT_CONFLICT';
    end if;

    return (round(coalesce(total, 0), 4), round(name_sim, 4), round(brand_sim, 4), round(size_sim, 4),
            round(var_sim, 4), round(cat_sim, 4), ok, reason)::silver.score_t;
end $$;

-- ---------------------------------------------------------------------------
-- Canonical row creation
-- ---------------------------------------------------------------------------
create or replace function silver.new_canonical(p_product_key int, p_method text default 'auto')
returns text language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare f silver.match_feat; p silver.dim_product%rowtype; v_id text;
begin
    select * into p from silver.dim_product where product_key = p_product_key;
    f := silver.features_of(p_product_key);
    insert into silver.canonical_product (
        sidnl_id, brand_key, canonical_name, name_clean, variant, variant_key, product_type,
        size_value, size_unit, pack_count, category_l1, category_l2, category_l3,
        anchor_product_key, created_method)
    values (silver.next_sidnl_id(), p.brand_key, p.product_name, f.name_clean, p.variant, f.variant_key, p.product_type,
            p.size_value, p.size_unit, coalesce(p.pack_count, 1), f.cat_l1, f.cat_l2, f.cat_l3,
            p_product_key, p_method)
    returning sidnl_id into v_id;
    return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- map_product: assign ONE dim_product to an SI id.  Idempotent.
-- ---------------------------------------------------------------------------
create or replace function silver.map_product(p_product_key int)
returns text language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare
    p silver.dim_product%rowtype;
    f silver.match_feat;
    th_auto numeric := silver.cfg('th_auto');  th_rev numeric := silver.cfg('th_review');
    v_sid text; v_status text; v_method text; v_score numeric := 1; v_detail jsonb := '{}'::jsonb;
    b record;
begin
    select * into p from silver.dim_product where product_key = p_product_key;
    if not found then raise exception 'unknown product_key %', p_product_key; end if;

    select sidnl_id into v_sid from silver.product_xref where product_key = p_product_key;
    if found then return v_sid; end if;

    perform pg_advisory_xact_lock(727102);                 -- serialise SI id assignment
    f := silver.features_of(p_product_key);

    -- Tier 0: the client's own catalog link (public.products) - ground truth, score 1.0
    if p.catalog_product_id is not null then
        select x.sidnl_id into v_sid
        from silver.product_xref x
        join silver.dim_product d on d.product_key = x.product_key
        where d.catalog_product_id = p.catalog_product_id
          and d.platform <> p.platform
          and not exists (select 1 from silver.product_xref x2
                          join silver.dim_product d2 on d2.product_key = x2.product_key
                          where x2.sidnl_id = x.sidnl_id and d2.platform = p.platform)
        order by x.matched_at, x.sidnl_id limit 1;
        if v_sid is not null then
            v_status := 'MAPPED'; v_method := 'CATALOG_LINK';
            v_detail := jsonb_build_object('catalog_product_id', p.catalog_product_id);
        end if;
    end if;

    -- Tier 1: attribute scoring against canonical products of the same brand + pack count,
    --         never against one that already holds a product of this platform.
    if v_sid is null then
        select c.sidnl_id as cand, s.* into b
        from silver.canonical_product c
        cross join lateral silver.score_pair(f, silver.canon_feat(c)) s
        where c.brand_key = p.brand_key and c.is_active and c.pack_count = coalesce(p.pack_count, 1)
          and not exists (select 1 from silver.product_xref x
                          join silver.dim_product d on d.product_key = x.product_key
                          where x.sidnl_id = c.sidnl_id and d.platform = p.platform)
        order by s.score desc, c.sidnl_id
        limit 1;

        if b.cand is not null then
            v_score  := b.score;
            v_detail := jsonb_build_object('candidate', b.cand, 'name', b.name_sim, 'brand', b.brand_sim,
                                           'size', b.size_sim, 'variant', b.variant_sim, 'category', b.category_sim,
                                           'rules', b.rule_reason);
        end if;

        if b.cand is not null and b.score >= th_auto and b.rule_ok then
            v_sid := b.cand; v_status := 'MAPPED'; v_method := 'ATTRIBUTE_AUTO';
        else
            v_sid := silver.new_canonical(p_product_key);
            if b.cand is not null and b.score >= th_rev then
                v_status := 'PENDING_REVIEW'; v_method := 'ATTRIBUTE_REVIEW';
                insert into silver.match_review_queue (product_key, suggested_sidnl_id, score, rule_ok, rule_reason, score_detail)
                values (p_product_key, b.cand, b.score, b.rule_ok, b.rule_reason, v_detail)
                on conflict (product_key, suggested_sidnl_id) do nothing;
            else
                v_status := 'NEW_MASTER'; v_method := 'NEW_MASTER';
                v_score := 1; v_detail := v_detail || jsonb_build_object('best_rejected_score', b.score);
            end if;
        end if;
    end if;

    insert into silver.product_xref (product_key, sidnl_id, match_status, match_method, score, score_detail)
    values (p_product_key, v_sid, v_status, v_method, v_score, v_detail);
    return v_sid;
end $$;

-- map_new_products: every dim_product without an SI id. Oldest first, so ids are stable.
create or replace function silver.map_new_products()
returns jsonb language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare r record; v_counts jsonb := '{}'::jsonb; s text;
begin
    for r in select p.product_key from silver.dim_product p
             where not exists (select 1 from silver.product_xref x where x.product_key = p.product_key)
             order by p.first_seen_at nulls last, p.product_key loop
        perform silver.map_product(r.product_key);
        select match_status into s from silver.product_xref where product_key = r.product_key;
        v_counts := jsonb_set(v_counts, array[s], to_jsonb(coalesce((v_counts ->> s)::int, 0) + 1));
    end loop;
    return v_counts;
end $$;

-- sync_canonical_attrs: canonical rows follow their anchor member (name fixes, new category, ...)
create or replace function silver.sync_canonical_attrs()
returns int language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare n int;
begin
    with x as (
        select c.sidnl_id, d.product_name, d.variant, d.product_type, d.size_value, d.size_unit,
               coalesce(d.pack_count, 1) pack_count, silver.features_of(c.anchor_product_key) f
        from silver.canonical_product c
        join silver.dim_product d on d.product_key = c.anchor_product_key
        where c.is_active)
    update silver.canonical_product c set
        canonical_name = x.product_name, name_clean = (x.f).name_clean, variant = x.variant,
        variant_key = (x.f).variant_key, product_type = x.product_type, size_value = x.size_value,
        size_unit = x.size_unit, pack_count = x.pack_count,
        category_l1 = (x.f).cat_l1, category_l2 = (x.f).cat_l2, category_l3 = (x.f).cat_l3
    from x
    where x.sidnl_id = c.sidnl_id
      and (c.canonical_name, c.name_clean, c.variant, c.variant_key, c.product_type, c.size_value, c.size_unit,
           c.pack_count, c.category_l1, c.category_l2, c.category_l3)
          is distinct from
          (x.product_name, (x.f).name_clean, x.variant, (x.f).variant_key, x.product_type, x.size_value, x.size_unit,
           x.pack_count, (x.f).cat_l1, (x.f).cat_l2, (x.f).cat_l3);
    get diagnostics n = row_count;
    return n;
end $$;

-- ---------------------------------------------------------------------------
-- Human decisions
-- ---------------------------------------------------------------------------
create or replace function silver.merge_canonical(p_from text, p_to text, p_by text default session_user)
returns text language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare f text := silver.sidnl_normalize(p_from); t text := silver.sidnl_normalize(p_to);
begin
    if f is null or t is null or f = t then raise exception 'need two different SI ids (got %, %)', p_from, p_to; end if;
    perform 1 from silver.canonical_product where sidnl_id in (f, t) and is_active having count(*) = 2;
    if not found then raise exception 'both SI ids must exist and be active'; end if;
    if exists (select 1 from silver.product_xref x1 join silver.dim_product d1 using (product_key)
               join silver.product_xref x2 on x2.sidnl_id = t
               join silver.dim_product d2 on d2.product_key = x2.product_key
               where x1.sidnl_id = f and d1.platform = d2.platform) then
        raise exception 'cannot merge % into %: both already have a product on the same platform', f, t;
    end if;

    update silver.product_xref set
        sidnl_id = t,
        match_status = case when match_status in ('PENDING_REVIEW','NEW_MASTER') then 'MANUAL' else match_status end,
        match_method = case when match_status in ('PENDING_REVIEW','NEW_MASTER') then 'REVIEW_APPROVED' else match_method end,
        reviewed_by = p_by, reviewed_at = now()
    where sidnl_id = f;

    update silver.canonical_product set is_active = false, merged_into = t where sidnl_id = f;
    update silver.match_review_queue set status = 'approved', decided_by = p_by, decided_at = now()
        where status = 'pending' and suggested_sidnl_id = t
          and product_key in (select product_key from silver.product_xref where sidnl_id = t);
    update silver.match_review_queue set suggested_sidnl_id = t
        where status = 'pending' and suggested_sidnl_id = f
          and not exists (select 1 from silver.match_review_queue q2
                          where q2.product_key = match_review_queue.product_key and q2.suggested_sidnl_id = t);
    delete from silver.match_review_queue where status = 'pending' and suggested_sidnl_id = f;
    return t;
end $$;

create or replace function silver.approve_match(p_review_id bigint, p_by text default session_user)
returns text language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare q silver.match_review_queue%rowtype; v_from text;
begin
    select * into q from silver.match_review_queue where review_id = p_review_id and status = 'pending' for update;
    if not found then raise exception 'review % not found or already decided', p_review_id; end if;
    select sidnl_id into v_from from silver.product_xref where product_key = q.product_key;
    if v_from = q.suggested_sidnl_id then
        update silver.match_review_queue set status = 'approved', decided_by = p_by, decided_at = now() where review_id = p_review_id;
        return v_from;
    end if;
    return silver.merge_canonical(v_from, q.suggested_sidnl_id, p_by);
end $$;

create or replace function silver.reject_match(p_review_id bigint, p_by text default session_user)
returns void language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare q silver.match_review_queue%rowtype;
begin
    select * into q from silver.match_review_queue where review_id = p_review_id and status = 'pending' for update;
    if not found then raise exception 'review % not found or already decided', p_review_id; end if;
    update silver.match_review_queue set status = 'rejected', decided_by = p_by, decided_at = now() where review_id = p_review_id;
    update silver.product_xref set match_status = 'NEW_MASTER', match_method = 'REVIEW_REJECTED',
           reviewed_by = p_by, reviewed_at = now()
     where product_key = q.product_key and match_status = 'PENDING_REVIEW'
       and not exists (select 1 from silver.match_review_queue q2
                       where q2.product_key = q.product_key and q2.status = 'pending');
end $$;

-- unmap_product: split a wrongly merged product out into its own new SI id.
create or replace function silver.unmap_product(p_product_key int, p_by text default session_user)
returns text language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare v_new text;
begin
    perform pg_advisory_xact_lock(727102);
    v_new := silver.new_canonical(p_product_key, 'manual');
    update silver.product_xref set sidnl_id = v_new, match_status = 'MANUAL', match_method = 'MANUAL_SPLIT',
           reviewed_by = p_by, reviewed_at = now()
     where product_key = p_product_key;
    if not found then raise exception 'product_key % has no SI id yet', p_product_key; end if;
    return v_new;
end $$;

-- ---------------------------------------------------------------------------
-- Self-tests. No invented data: real-product tests read silver.dim_product only,
-- the pure tests use abstract tokens. Every row should say ok = true.
-- ---------------------------------------------------------------------------
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
