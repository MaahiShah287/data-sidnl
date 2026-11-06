"""Gold layer: Dynamic multi-attribute matching with mathematical safety validation.

Purely logical, formula-based implementation with zero hardcoded brands, variant pairs, or static filters.
Works on any e-commerce catalog data adhering to the Supabase data fields.

1. Check 1 - Text Match (Lexical & Brand Similarity Formula):
   - Token-set similarity between normalized titles and brands.
   - Scale-invariant token matching.

2. Check 2 - Meaning / Semantic Match (Size, Variant & Taxonomy):
   - Relative size difference formula: Delta = |s1 - s2| / max(s1, s2)
   - Variant similarity & Category hierarchy alignment.

3. Check 3 - Strict Safety Rules (Formula-driven):
   - Pack count equality: |p1 - p2| == 0
   - Size limit: Delta_size <= 0.05 (5%)
   - Brand conflict: sim(b1, b2) >= 0.60
   - Variant conflict: sim(v1, v2) >= 0.40

4. Adaptive Weighting Formula:
   - Dynamic weights normalized over available attributes: W_i = w_i / sum(w_active)
   - Guarantees sum(W_i) == 1.0 (100%) for any product structure.
"""
from collections import defaultdict

try:
    from rapidfuzz import fuzz
except ImportError:
    import difflib
    class _FuzzFallback:
        @staticmethod
        def token_set_ratio(s1, s2):
            t1, t2 = set(str(s1).split()), set(str(s2).split())
            if not t1 and not t2: return 100.0
            if not t1 or not t2: return 0.0
            inter = t1 & t2
            if not inter: return round(difflib.SequenceMatcher(None, str(s1), str(s2)).ratio() * 100, 1)
            if inter == t1 or inter == t2:
                return 100.0
            s_inter = " ".join(sorted(inter))
            s1_all = s_inter + " " + " ".join(sorted(t1 - inter))
            s2_all = s_inter + " " + " ".join(sorted(t2 - inter))
            r1 = difflib.SequenceMatcher(None, s_inter, s1_all.strip()).ratio()
            r2 = difflib.SequenceMatcher(None, s_inter, s2_all.strip()).ratio()
            r3 = difflib.SequenceMatcher(None, s1_all.strip(), s2_all.strip()).ratio()
            return round(max(r1, r2, r3) * 100, 1)
    fuzz = _FuzzFallback()

from .common import load_yaml, connect
from .normalize import compact

LOCK_ID = 727001


def compute_match_score(src, cand, w):
    """Compute adaptive weighted score using mathematical normalization over present attributes."""
    # Check 1: Text Match (Product Name & Brand)
    s_name = src.get("name_clean") or ""
    c_name = cand.get("canonical_name") or ""
    name_sim = 1.0 if (not s_name and not c_name) else fuzz.token_set_ratio(s_name, c_name) / 100.0

    s_b = src.get("brand") or ""
    c_b = cand.get("brand") or ""
    has_brand = bool(s_b or c_b)
    if not has_brand:
        brand_sim = 1.0
    elif compact(s_b) == compact(c_b):
        brand_sim = 1.0
    elif not s_b or not c_b:
        brand_sim = 0.5
    else:
        ratio = fuzz.token_set_ratio(s_b, c_b)
        brand_sim = ratio / 100.0 if ratio >= 60 else 0.0

    # Check 2: Meaning & Attributes (Size, Variant, Category)
    s_p = src.get("pack_count") or 1
    c_p = cand.get("pack_count") or 1
    s_size = src.get("size_base")
    c_size = cand.get("size_base")
    has_size = (s_size is not None or c_size is not None)

    if s_p != c_p:
        size_sim = 0.0
    elif not has_size:
        size_sim = 1.0
    elif s_size is None or c_size is None:
        size_sim = 0.5
    else:
        # Relative difference formula: Delta = |s1 - s2| / max(s1, s2)
        diff_pct = abs(s_size - c_size) / max(s_size, c_size, 0.001)
        if diff_pct <= 0.01:
            size_sim = 1.0
        elif diff_pct <= 0.05:
            size_sim = 0.8
        else:
            size_sim = 0.0

    s_v = src.get("variant") or ""
    c_v = cand.get("variant") or ""
    has_variant = bool(s_v or c_v)
    if not has_variant:
        var_sim = 1.0
    elif s_v == c_v:
        var_sim = 1.0
    elif not s_v or not c_v:
        var_sim = 0.5
    else:
        var_sim = fuzz.token_set_ratio(s_v, c_v) / 100.0

    s_l1, s_l2, s_l3 = src.get("category_l1"), src.get("category_l2"), src.get("category_l3")
    c_l1, c_l2, c_l3 = cand.get("category_l1"), cand.get("category_l2"), cand.get("category_l3")
    has_cat = bool(s_l1 or c_l1)
    if not has_cat:
        cat_sim = 1.0
    elif s_l1 == c_l1:
        if s_l2 == c_l2:
            cat_sim = 1.0 if s_l3 == c_l3 else 0.9
        else:
            cat_sim = 0.75
    elif (s_l3 and c_l3 and s_l3 == c_l3) or (s_l2 and c_l2 and s_l2 == c_l2):
        cat_sim = 0.85
    else:
        cat_sim = 0.0

    # Adaptive Dynamic Weighting Formula:
    # W_i = w_i / sum(w_active), ensuring sum(W_i) == 1.0
    base_weights = {
        "name": (w.get("name", 0.35), name_sim, True),
        "brand": (w.get("brand", 0.25), brand_sim, has_brand),
        "size": (w.get("size", 0.20), size_sim, has_size),
        "variant": (w.get("variant", 0.15), var_sim, has_variant),
        "category": (w.get("category", 0.05), cat_sim, has_cat),
    }
    active_weight_sum = sum(weight for weight, _, active in base_weights.values() if active)
    if active_weight_sum <= 0:
        active_weight_sum = 1.0

    total = sum((weight / active_weight_sum) * sim for weight, sim, active in base_weights.values() if active)
    return round(total, 4), brand_sim, size_sim


def check_strict_rules(src, cand, brand_sim, size_sim):
    """Deterministic Safety Rules by Formula. Zero predefined variant or brand lists."""
    # 1. Pack count agreement: |p1 - p2| == 0
    p1 = src.get("pack_count") or 1
    p2 = cand.get("pack_count") or 1
    if p1 != p2:
        return False, "PACK_COUNT_MISMATCH"

    # 2. Size agreement by relative difference formula: Delta = |s1 - s2| / max(s1, s2)
    s_size, c_size = src.get("size_base"), cand.get("size_base")
    if s_size is not None and c_size is not None:
        diff_pct = abs(s_size - c_size) / max(s_size, c_size, 0.001)
        if diff_pct > 0.05:
            return False, "SIZE_MISMATCH"

    # 3. Brand conflict formula: distinct brands with low token similarity
    s_b, c_b = src.get("brand"), cand.get("brand")
    if s_b and c_b and brand_sim < 0.60:
        return False, "BRAND_CONFLICT"

    # 4. Variant conflict formula: non-empty distinct variants with low token similarity (< 40%)
    s_v, c_v = src.get("variant") or "", cand.get("variant") or ""
    if s_v and c_v and s_v != c_v:
        v_sim = fuzz.token_set_ratio(s_v, c_v) / 100.0
        if v_sim < 0.40:
            return False, "VARIANT_CONFLICT"

    return True, "PASSED"


def _cohort(cur, cache, brand, size, pack):
    """Fetch candidate master products efficiently by cohort."""
    key = (brand, size, pack)
    c = cache.get(key)
    if c is None:
        if len(cache) > 100_000:
            cache.clear()
        size_sql, args = ("size_base is null", (brand, pack)) if size is None else ("size_base = %s", (brand, size, pack))
        cur.execute(
            f"select master_id, brand, size_base, size_unit, pack_count, variant, "
            f"category_l1, category_l2, category_l3, coalesce(canonical_name,'') "
            f"from sidnl.master_products where brand = %s and {size_sql} and pack_count = %s",
            args,
        )
        c = cache[key] = [
            {
                "master_id": r[0], "brand": r[1], "size_base": r[2], "size_unit": r[3],
                "pack_count": r[4], "variant": r[5], "category_l1": r[6], "category_l2": r[7],
                "category_l3": r[8], "canonical_name": r[9]
            }
            for r in cur.fetchall()
        ]
        if not c and brand:
            cur.execute(
                "select master_id, brand, size_base, size_unit, pack_count, variant, "
                "category_l1, category_l2, category_l3, coalesce(canonical_name,'') "
                "from sidnl.master_products where brand = %s and pack_count = %s limit 50",
                (brand, pack),
            )
            c = [
                {
                    "master_id": r[0], "brand": r[1], "size_base": r[2], "size_unit": r[3],
                    "pack_count": r[4], "variant": r[5], "category_l1": r[6], "category_l2": r[7],
                    "category_l3": r[8], "canonical_name": r[9]
                }
                for r in cur.fetchall()
            ]
            cache[key] = c
    return c


def run(batch=20_000):
    cfg = load_yaml("matching.yaml")
    w = cfg.get("weights", {"name": 0.35, "brand": 0.25, "size": 0.20, "variant": 0.15, "category": 0.05})
    th = cfg.get("thresholds", {"auto_match": 0.90, "review": 0.75})
    conn = connect()

    with conn.cursor() as cur:
        cur.execute("select pg_try_advisory_lock(%s)", (LOCK_ID,))
        if not cur.fetchone()[0]:
            conn.close()
            return {}
    conn.commit()

    cache, counts = {}, defaultdict(int)
    while True:
        with conn.cursor() as cur:
            cur.execute("""select pf.source_id, pf.brand, pf.size_base, pf.size_unit,
                                  pf.pack_count, pf.variant, pf.category_l1, pf.category_l2, pf.category_l3, pf.name_clean
                           from sidnl.product_features pf
                           left join sidnl.product_map pm using (source_id)
                           where pm.source_id is null order by pf.source_id limit %s""", (batch,))
            rows = cur.fetchall()
            if not rows:
                break
            maps = []
            for sid, brand, size, unit, pack, variant, cl1, cl2, cl3, nc in rows:
                src = {
                    "source_id": sid, "brand": brand, "size_base": size, "size_unit": unit,
                    "pack_count": pack, "variant": variant, "category_l1": cl1, "category_l2": cl2,
                    "category_l3": cl3, "name_clean": nc,
                }

                cands = _cohort(cur, cache, brand, size, pack)
                best_mid, best_s, best_passes = None, -1.0, False

                for cand in cands:
                    s, b_sim, sz_sim = compute_match_score(src, cand, w)
                    passes, _ = check_strict_rules(src, cand, b_sim, sz_sim)
                    if s > best_s:
                        best_mid, best_s, best_passes = cand["master_id"], s, passes

                # Three-way resolution
                if best_mid is not None and best_s >= th["auto_match"] and best_passes:
                    maps.append((sid, best_mid, best_s, "MAPPED", "ATTRIBUTE_AUTO"))
                    counts["MAPPED"] += 1
                elif best_mid is not None and best_s >= th["review"]:
                    maps.append((sid, best_mid, best_s, "PENDING_REVIEW", "ATTRIBUTE_REVIEW"))
                    counts["PENDING_REVIEW"] += 1
                else:
                    cur.execute(
                        """insert into sidnl.master_products
                           (brand, size_base, size_unit, pack_count, variant, category_l1, category_l2, category_l3, canonical_name)
                           values (%s,%s,%s,%s,%s,%s,%s,%s,%s) returning master_id""",
                        (brand, size, unit, pack, variant, cl1, cl2, cl3, nc),
                    )
                    mid = cur.fetchone()[0]
                    new_cand = {
                        "master_id": mid, "brand": brand, "size_base": size, "size_unit": unit,
                        "pack_count": pack, "variant": variant, "category_l1": cl1, "category_l2": cl2,
                        "category_l3": cl3, "canonical_name": nc,
                    }
                    _cohort(cur, cache, brand, size, pack).append(new_cand)
                    maps.append((sid, mid, 1.0, "UNMAPPED", "NEW_MASTER"))
                    counts["UNMAPPED"] += 1

            cur.executemany(
                """insert into sidnl.product_map (source_id, master_id, score, status, match_type)
                   values (%s,%s,%s,%s,%s) on conflict (source_id) do nothing""",
                maps,
            )
        conn.commit()
        print(dict(counts))
    conn.commit()
    conn.close()
    return dict(counts)
