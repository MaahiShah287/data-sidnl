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
    t := regexp_replace(t, '(\d),(\d{3})\y', '\1\2', 'g');
    t := regexp_replace(t, '(\d),(\d{1,2})\y', '\1.\2', 'g');
    t := regexp_replace(t, '\m(litres?|liters?|ltrs?|ltr)\M', 'l', 'g');
    t := regexp_replace(t, '\m(millilit(?:re|er)s?)\M', 'ml', 'g');
    t := regexp_replace(t, '\m(grams?|gms?|gm)\M', 'g', 'g');
    t := regexp_replace(t, '\m(kgs?|kilograms?)\M', 'kg', 'g');

    m := regexp_match(t, '(\d+)\s*[x×*]\s*(\d+(?:\.\d+)?)\s*(kg|g|ml|l)\M');
    if m is not null then
        cnt := m[1]::int;  v := m[2]::numeric;  u := m[3];
    else
        m := regexp_match(t, '(\d+(?:\.\d+)?)\s*(kg|g|ml|l)\M');
        if m is not null then
            v := m[1]::numeric;  u := m[2];
        end if;
        m := regexp_match(t, '(\d+)\s*(?:pcs?|pieces?|units?|n)\M');
        if m is not null then cnt := m[1]::int;
        else
            m := regexp_match(t, 'pack of\s*(\d+)');
            if m is not null then cnt := m[1]::int; end if;
        end if;
    end if;

    if u is null then
        return (case when cnt is not null then cnt::numeric end, 'pc', coalesce(cnt, 1))::silver.pack_t;
    end if;

    if u = 'kg' then v := v * 1000; u := 'g';
    elsif u = 'l' then v := v * 1000; u := 'ml';
    end if;

    return (v, u, greatest(coalesce(cnt, 1), 1))::silver.pack_t;
end $$;