# Canonical product mapping audit: silver vs raw (2026-11-10)

Read-only audit of the live project `jqxnaqbvwgmfkyzfincy`. Nothing was changed. The self-tests ran inside a
transaction that was rolled back. "Bronze" means every schema except `silver` and `dash` (today that is the
`public` tables; `ecomscraper` is empty). Every number below comes from a query against the live data.

## Verdict
- **The silver values copied from bronze are exact.** Product names, pack strings, prices, MRPs, inventory, positions,
  ad flags and timestamps match their bronze source row in every compared row (1.83M shelf rows, 15,428 readings,
  7,149 products). Nothing in silver lacks a bronze source row.
- **The SI id structure is clean.** One SI id per product, no orphans, ids `SI001`–`SI7141` contiguous and in the
  documented A–Z order.
- **Defects found (not zero):**
  1. A pack-parse bug gives **13 products the wrong pack count** (`total_content` understated).
  2. **63 products have a `first_seen_at` later than the real first bronze sighting.**
  3. **Cross-platform matching is not automatic.** No SI id spans two platforms. Correct Blinkit↔Zepto matches wait in
     a manual review queue, and that queue also holds wrong suggestions with high scores.
  4. **10,787 bronze observations are not in silver** because their brands are outside `silver.brand_scope`
     (a scope rule, not a load failure).
  5. One stale review-queue row.

## 1. Lineage and completeness
| Check | Result |
|---|---|
| `silver.dim_product` rows vs `public.platform_products` | 7,149 = 7,149 (blinkit 6,967, zepto 182); 0 missing either way |
| Duplicate `(platform, platform_product_id)` in silver | 0 |
| `listing_id` / `catalog_product_id` without a bronze row | 0 / 0 |
| `fact_shelf_position` vs `public.shelf_positions` | 1,832,098 = 1,832,098; 0 missing either way |
| `fact_product_reading` from `public.search_cards` | 8,058 = 8,058; 0 missing |
| `fact_product_reading` from `public.observations` | 7,370 of 18,157 (see §5) |
| Readings from `public.shelf_positions` without a bronze row | 0 |
| Duplicate source rows in `fact_product_reading` | 0 |

## 2. Values vs bronze (row-by-row, `is distinct from`)
| Table | Fields compared | Mismatches |
|---|---|---|
| dim_product vs platform_products | product_name, pack_raw | 0 / 0 |
| fact_shelf_position vs shelf_positions | price, mrp, inventory, position, organic_position, is_ad, external_id, snapshot_id | all 0 |
| readings vs observations | price, mrp, inventory, inventory_capped, observed_at, state | all 0 |
| readings vs search_cards | price, mrp, inventory, position, organic_position, is_ad | all 0 |
| dim_product.image_url | 8 differ from `platform_products` (`.jpg` vs `.png`) | the `.jpg` URL is present in bronze `platform_listings`, `products` and `listing_snapshots`, so it is sourced, not invented |
| dim_product.last_seen_at | = max observed_at of its facts for 7,149 / 7,149 | 0 |
| dim_product.first_seen_at | = min observed_at of its facts for 7,086; **63 are later than both the facts and bronze** | **defect 2** |

## 3. SI ids and canonical records
| Check | Result |
|---|---|
| Products without an SI id / xref rows pointing to a missing product / product with 2 xrefs | 0 / 0 / 0 |
| xref pointing to a missing or retired SI id / active SI id with no product | 0 / 0 |
| SI id format `^SI[0-9]+$`; contiguous 1..7141 in resequence order (`lower(name), brand, size, pack`) | 0 bad; 0 out of order |
| Canonical anchor missing or not a member; canonical name ≠ anchor's bronze name | 0; 0 |
| Canonical brand/size/unit/pack ≠ any member's; SI id holding two brands | 0; 0 |
| SI ids with two products of the same platform | 8, all exact duplicates in bronze (same name, brand and pack, different `external_id`, e.g. "Perrier Sparkling Water" 330 ml, ids 120190 and 1409145). Correct by the documented rule. 63 g and 2 x 63 g stayed separate. |
| Match status | NEW_MASTER 7,097 · MAPPED (exact name+pack) 8 · PENDING_REVIEW 44 |
| Built-in tests (`selftest_parser`, `selftest_matcher`, `quality_checks`) | all pass. **They do not cover defect 1.** |

## 4. Defects
**D1. Pack multiplier after the size is dropped (13 products).** `silver.parse_pack` handles `2 x 100 g` (→ 2 × 100 g) but
returns pack_count **1** for `100 g X 2`, `500 ml X 4` and `2 x 1 pc`. Affected: 10 Zepto "Combo" products (`100 g X 2`,
`200 g X 4`, `60 ml X 2|3`, `120 ml X 2|3`, `500 ml X 2|4`) and 3 Blinkit `2 x 1 pc` products (HyFun Margherita Toastie,
HyFun Cheesy Garlic Toasties, Amul Mini Margherita Pizza). Effect: `total_content` and `price_per_100g` are understated,
and the matcher suggested merging "Amul Shrikhand Elaichi Combo 100 g X 2" with the single 100 g SKU (score 0.975, rules passed).
(`2 x 45 g + 35 g` = 125 g is parsed correctly.)

**D2. `first_seen_at` too late (63 products).** Example: "McCain Super Potato Wedges": silver says 2026-11-07 17:46,
but its first shelf fact and bronze `platform_products.first_seen_at` say 2026-10-29 01:57. The value is set when silver
creates the product and is never moved earlier.

**D3. Cross-platform matching.** No SI id spans two platforms. `auto_merge_fuzzy = 0`, so only an identical raw pack
string merges automatically, and Zepto writes packs as `1 pack (1.25 kg)` where Blinkit writes `1.25 kg`. Of 45 pending
reviews (28 Zepto, 17 Blinkit):
- **4 are certain matches** (same brand, identical name, identical parsed size/unit/pack, other platform): Amul Happy Treats
  French Fries 1.25 kg (SI429→SI428), Amul Margherita Pizza 210 g (SI475→SI474), Amul Mango Shrikhand 500 g (SI473→SI472),
  Amul Real Mango Amrakhand 200 g (SI524→SI523).
- **Many suggestions are wrong even at score 0.975 with rules passed**: "Gud Shrikhand- Badam Pista" → "Gud Shrikhand";
  "Elaichi Nankhatai" → "Elaichi Shrikhand"; "Cheese Spread Spicy Garlic" → "Garlic Pizza"; "Hazelnut Chocolate Bar" →
  "Dark Chocolate Bar"; Combo X 2/X 4 → single (D1). **Turning on fuzzy auto-merge would create wrong merges and wrong numbers.**

**D4. Brand scope (10,787 observations not in silver).** Only 3 brands are enabled in `silver.brand_scope` (amul, mother dairy,
mr munchies; 826 others are disabled). Stock-check rows for Lay's (3,112), Coca-Cola (2,422), Pepsi (2,054), Bikano (1,494),
KitKat (1,259), Bournville (167), Maggi (63), no brand (50) and demo (166) are not loaded. Category-shelf data is loaded for all brands.

**D5.** `match_review_queue` review_id 2 (product 1108) is still `pending` although its xref is already NEW_MASTER.

## 5. Fixes
1. **D1, DONE: `silver_056_parse_pack_counts`** (version `20261110101147`, exact SQL in
   `sql/silver/live/20261110101147_silver_056_parse_pack_counts.sql`, rollback `sql/silver/056_rollback.sql`).
   While fixing it, the full sweep over every bronze pack pattern found the defect is **2,106 products, not 13**:
   `N tabs` 1,670 and `N capsules` 185 had lost their count (1 pc); `N pcs` 219 and `N units` 5 had total = N²;
   `2 x 10 pcs` 8 → total 100; `N ml/g X N` 10, `2 x 1 pc` 3, `40U x 25g`, `4 packs`, `30 sheets`, `1 unit + 1 unit`;
   `7 pcs + 102 g` 2 had been multiplied to 714 g. New convention: size = content of one pack (g/ml/pc), pack_count = number
   of packs, total = size × count. The pre-apply dry run (rolled back) showed: only those patterns change; 13 are g/ml rows; the
   full parser self-test (now with all these bronze strings) passes; quality checks pass; 0 SI ids renumbered; the rollback restores
   both function md5s and every row. The parser and its self-test are replaced in one migration because `quality_checks()` runs the self-test.
   Remaining effect on dash: `pricing.price_per_100g` changes for the 13 g/ml products at the next gold refresh.
2. `first_seen_at = least(current, min observed_at)` in the loader; one-time correction of the 63 rows from their own facts.
3. A **deterministic** cross-platform rule: auto-merge only when brand_key, normalized name and parsed size/unit/pack are all identical
   (4 today). Keep fuzzy auto-merge **off**. Anything else stays a separate SI id per platform. That never produces a wrong number;
   it only means those SKUs are not compared across platforms until reviewed.
4. Close stale review 2.
5. Decide whether `brand_scope` should load stock checks for all brands (D4).
