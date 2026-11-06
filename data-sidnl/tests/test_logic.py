"""Pure-logic tests (no database needed):  python -m unittest discover -s tests -v"""
import sys, time, unittest, datetime as dt, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import pandas as pd, yaml
from sidnl.normalize import Lexicon, clean, compact, parse_category
from sidnl import rules, loader, match

CFG = yaml.safe_load(open(pathlib.Path(__file__).resolve().parent.parent / "config" / "matching.yaml"))
LEX = Lexicon.from_yaml(CFG)


class Normalizer(unittest.TestCase):
    def test_same_product_two_platforms_identical_features(self):
        a = LEX.features("Thums Up 750ml PET", "ThumsUp", "750 ml")          # size also glued to name
        b = LEX.features("Thums Up Soft Drink 750 ml", "Thums Up", "750 ml")
        self.assertEqual((a["brand"], a["size_base"], a["name_clean"]), (b["brand"], b["size_base"], b["name_clean"]))
        self.assertEqual(a["name_clean"], "")      # 'pet' / 'soft drink' are seeded noise words

    def test_apostrophe_brand(self):
        a = LEX.features("Lays Magic Masala Chips 52 g", "Lay's", "52 g")
        b = LEX.features("Lay's Magic Masala 52g", "Lays", None)
        self.assertEqual(a["brand"], "lays"); self.assertEqual(a["brand"], b["brand"])
        self.assertNotIn("lays", a["name_clean"].split())

    def test_pack_and_units(self):
        f = LEX.features("Coca-Cola Soft Drink 6 x 330 ml Can", "Coca Cola", None)
        self.assertEqual((f["brand"], f["size_base"], f["size_unit"], f["pack_count"]), ("cocacola", 330.0, "ml", 6))
        self.assertEqual(LEX.features("Coke 330 ml x 6", None, None)["pack_count"], 6)
        self.assertEqual(LEX.parse_size("0,33 L")[0], 330.0)                   # decimal comma
        self.assertEqual(LEX.parse_size("1,000 ml")[0], 1000.0)                # thousands comma
        self.assertEqual(LEX.parse_size("1.5 kg")[:2], (1500.0, "g"))
        self.assertEqual(LEX.parse_size("Pack of 4", "250 g")[2], 4)

    def test_alias_and_variants(self):
        f = LEX.features("Coke Zero Sugar 300 ml", None, None)                # brand inferred from NAME via manual alias
        self.assertEqual((f["brand"], f["variant"]), ("cocacola", "zero"))
        self.assertEqual(LEX.features("Diet Pepsi 300ml", "Pepsi", None)["variant"], "diet")

    def test_unknown_brand_and_non_beverage(self):
        f = LEX.features("Roadster Men Slim Fit Jeans", "Roadster", "M")
        self.assertEqual((f["brand"], f["size_base"]), ("roadster", None))
        self.assertEqual(f["name_clean"], "fit jeans men slim")

    def test_learned_brand_is_start_only(self):
        lex = Lexicon(CFG_UNITS := {k: tuple(v) for k, v in CFG["units"].items()},
                      [("amul", "amul", False), ("fresh", "fresh", False)], {}, set())
        self.assertEqual(lex.features("Amul Taaza Toned Milk 1 L", None, None)["brand"], "amul")
        self.assertEqual(lex.features("Toned Milk Amul 1 L", None, None)["brand"], "")      # auto alias not at the start
        self.assertEqual(lex.features("Farm Fresh Eggs 6 pcs", None, None)["brand"], "")

    def test_speed_does_not_depend_on_brand_count(self):
        def rate(k):
            brands = [(f"brand {i}", f"brand {i}", False) for i in range(k)]
            lex = Lexicon({u: tuple(v) for u, v in CFG["units"].items()}, brands, {}, set())
            t = time.perf_counter()
            for _ in range(3000): lex.features("Amul Taaza Toned Milk 1 L", "Amul", "1 L")
            return 3000 / (time.perf_counter() - t)
        r10, r50k = rate(10), rate(50_000)
        print(f"\n   rows/sec/core: {r10:,.0f} with 10 brands, {r50k:,.0f} with 50,000 brands")
        self.assertGreater(r50k, r10 * 0.5)

    def test_dynamic_brands_without_hardcoded_yaml(self):
        """Validates that brands like Dove, Samsung, Amul are normalized and matched dynamically with NO YAML entries."""
        # Platform A: Dove Intense Repair Shampoo 340 ml
        # Platform B: Dove Repair Shampoo - 340ml
        # Platform C: Dove Intense Repair Hair Shampoo 0.34 L
        f_a = LEX.features("Dove Intense Repair Shampoo 340 ml", "Dove", "340 ml", "Beauty > Hair Care > Shampoo")
        f_b = LEX.features("Dove Repair Shampoo - 340ml", "Dove", "340ml", "Personal Care > Hair Care > Shampoo")
        f_c = LEX.features("Dove Intense Repair Hair Shampoo 0.34 L", "Dove", "0.34 L", "Hair Products > Shampoo")

        self.assertEqual(f_a["brand"], "dove")
        self.assertEqual(f_b["brand"], "dove")
        self.assertEqual(f_c["brand"], "dove")
        self.assertEqual(f_a["size_base"], 340.0)
        self.assertEqual(f_b["size_base"], 340.0)
        self.assertEqual(f_c["size_base"], 340.0)

        # 3-Check matching across platforms (No barcode)
        w = CFG["weights"]
        cand_b = {"canonical_name": f_b["name_clean"], "brand": f_b["brand"],
                  "size_base": f_b["size_base"], "size_unit": f_b["size_unit"],
                  "pack_count": f_b["pack_count"], "variant": f_b["variant"],
                  "category_l1": f_b["category_l1"], "category_l2": f_b["category_l2"], "category_l3": f_b["category_l3"]}
        score_ab, b_sim, sz_sim = match.compute_match_score(f_a, cand_b, w)
        passes, _ = match.check_strict_rules(f_a, cand_b, b_sim, sz_sim)
        self.assertTrue(passes)
        self.assertGreaterEqual(score_ab, 0.90)

    def test_samsung_galaxy_cross_platform_matching(self):
        """Platform A: Samsung Galaxy S24 128GB Black
           Platform B: Samsung S24 128 GB - Black
           Platform C: Samsung Galaxy S24 Smartphone Black 128 GB"""
        f_a = LEX.features("Samsung Galaxy S24 128GB Black", "Samsung", None, "Electronics > Mobiles > Smartphones")
        f_b = LEX.features("Samsung S24 128 GB - Black", "Samsung", None, "Electronics > Mobile Phones > Smartphones")
        f_c = LEX.features("Samsung Galaxy S24 Smartphone Black 128 GB", "Samsung", None, "Mobiles > Smartphones")

        self.assertEqual(f_a["brand"], "samsung")
        self.assertEqual(f_b["brand"], "samsung")
        self.assertEqual(f_c["brand"], "samsung")
        self.assertIn("black", f_a["variant"])
        self.assertIn("black", f_b["variant"])
        self.assertIn("black", f_c["variant"])

        w = CFG["weights"]
        cand_b = {"canonical_name": f_b["name_clean"], "brand": f_b["brand"],
                  "size_base": f_b["size_base"], "size_unit": f_b["size_unit"],
                  "pack_count": f_b["pack_count"], "variant": f_b["variant"],
                  "category_l1": f_b["category_l1"], "category_l2": f_b["category_l2"], "category_l3": f_b["category_l3"]}
        score_ab, b_sim, sz_sim = match.compute_match_score(f_a, cand_b, w)
        passes, _ = match.check_strict_rules(f_a, cand_b, b_sim, sz_sim)
        self.assertTrue(passes)
        self.assertGreaterEqual(score_ab, 0.90)

    def test_strict_rules_prevent_false_positives(self):
        """Tests Check 3 (Strict Safety Rules from workflow): 500ml != 1L, single != 6-pack, brand conflict."""
        w = CFG["weights"]
        src = {"name_clean": "coca cola", "brand": "cocacola", "size_base": 500.0, "size_unit": "ml", "pack_count": 1, "variant": ""}
        cand_1L = {"canonical_name": "coca cola", "brand": "cocacola", "size_base": 1000.0, "size_unit": "ml", "pack_count": 1, "variant": ""}
        cand_pack6 = {"canonical_name": "coca cola", "brand": "cocacola", "size_base": 500.0, "size_unit": "ml", "pack_count": 6, "variant": ""}
        cand_pepsi = {"canonical_name": "coca cola", "brand": "pepsi", "size_base": 500.0, "size_unit": "ml", "pack_count": 1, "variant": ""}

        # 500ml vs 1L fails size check
        _, b_sim, sz_sim = match.compute_match_score(src, cand_1L, w)
        passes, reason = match.check_strict_rules(src, cand_1L, b_sim, sz_sim)
        self.assertFalse(passes)
        self.assertEqual(reason, "SIZE_MISMATCH")

        # 1-pack vs 6-pack fails pack count check
        _, b_sim, sz_sim = match.compute_match_score(src, cand_pack6, w)
        passes, reason = match.check_strict_rules(src, cand_pack6, b_sim, sz_sim)
        self.assertFalse(passes)
        self.assertEqual(reason, "PACK_COUNT_MISMATCH")

        # Coke vs Pepsi fails brand conflict check
        _, b_sim, sz_sim = match.compute_match_score(src, cand_pepsi, w)
        passes, reason = match.check_strict_rules(src, cand_pepsi, b_sim, sz_sim)
        self.assertFalse(passes)
        self.assertEqual(reason, "BRAND_CONFLICT")

    def test_category_parsing(self):
        l1, l2, l3 = parse_category("Electronics > Mobile Phones -> Smartphones")
        self.assertEqual((l1, l2, l3), ("electronics", "mobile phones", "smartphones"))


class Learning(unittest.TestCase):
    def test_brand_aggregation_merges_spellings(self):
        out = rules.aggregate_brands([("Thums Up", 50), ("ThumsUp", 5), ("thums-up", 2), ("Rare", 1), ("NA", 999), ("12", 99)],
                                     min_count=3, ignore=["na"])
        self.assertEqual(out["thums up"][0], "thums up"); self.assertEqual(out["thumsup"][0], "thums up")
        self.assertNotIn("rare", out); self.assertNotIn("na", out); self.assertNotIn("12", out)

    def test_noise_candidates(self):
        rows = [("Cold Drinks", f"Brand{i} Soft Drink {i} ml") for i in range(300)] + \
               [("Cold Drinks", f"Cola Special{i}") for i in range(50)] + [("Tiny", "Soft Drink")] * 10
        out = rules.noise_candidates(rows, min_group=200, min_df=0.30)
        self.assertIn("soft", out); self.assertIn("drink", out); self.assertNotIn("special0", out)


class Loader(unittest.TestCase):
    def test_prepare(self):
        df = pd.DataFrame({"product_id": [" A1", "A1", "B2", "", None, "C3"], "name": ["x"] * 6,
                           "price": ["₹1,299.00", "1199", "50", "5", "5", "abc"], "mrp": ["1500"] * 6,
                           "in_stock": ["In Stock", "no", "", "1", "1", "yes"],
                           "scraped_at": ["2026-11-01 08:00", "2026-11-02 08:00", "1970-01-01", "2026-11-02", "2026-11-02", None]})
        cm = {"platform_product_id": "product_id", "name": "name", "price": "price", "mrp": "mrp",
              "in_stock": "in_stock", "observed_at": "scraped_at"}
        now = dt.datetime(2026, 11, 2, 12, tzinfo=dt.timezone.utc)
        o = loader.prepare(df, cm, {"1", "yes", "in stock"}, now)
        self.assertEqual(len(o), 4)                                            # blank/None ids dropped, both A1 observations KEPT
        self.assertEqual(list(o["price"].round(0).fillna(-1)), [1299, 1199, 50, -1])
        self.assertEqual(o["in_stock"].tolist()[:3], [True, False, pd.NA])
        self.assertEqual(o.loc[o.platform_product_id == "B2", "observed_at"].iloc[0], pd.Timestamp(now))   # 1970 -> now
        self.assertIn('"price":"₹1,299.00"', o["raw"].iloc[0].replace(" ", ""))
        o["platform"] = "p"
        csv = o[loader.COLS].to_csv(index=False, header=False, na_rep="\\N")
        print("\n   COPY payload sample:", csv.splitlines()[2][:110])
        self.assertIn("\\N", csv)

    def test_prepare_speed(self):
        n = 200_000
        df = pd.DataFrame({"product_id": [str(i) for i in range(n)], "name": ["Amul Taaza Milk 1 L"] * n, "brand": ["Amul"] * n,
                           "unit": ["1 L"] * n, "category": ["Dairy"] * n, "url": ["http://x/y"] * n, "price": ["54"] * n,
                           "mrp": ["56"] * n, "in_stock": ["1"] * n, "scraped_at": ["2026-11-02 08:00:00"] * n})
        cm = {"platform_product_id": "product_id", "name": "name", "brand": "brand", "size": "unit", "category": "category",
              "url": "url", "price": "price", "mrp": "mrp", "in_stock": "in_stock", "observed_at": "scraped_at"}
        t = time.perf_counter()
        o = loader.prepare(df, cm, {"1"}, dt.datetime.now(dt.timezone.utc)); o["platform"] = "p"
        csv = o[loader.COLS].to_csv(index=False, header=False, na_rep="\\N")
        print(f"\n   prepare + CSV for {n:,} rows: {time.perf_counter() - t:.1f}s  ({len(csv)/1e6:.0f} MB)")

    def test_auto_detect_columns_unknown_platform(self):
        """Verifies loader works on ANY unconfigured platform without hardcoded platforms.yaml."""
        df = pd.DataFrame({
            "item_id": ["SKU123"], "product_title": ["Dove Deep Moisture Shampoo 340 ml"],
            "brand_name": ["Dove"], "pack_size": ["340 ml"], "category_path": ["Beauty > Hair"],
            "selling_price": ["299.00"], "mrp_price": ["350.00"], "stock_status": ["in stock"],
            "scraped_time": ["2026-11-02 10:00:00"]
        })
        # colmap is None -> dynamically resolved by header heuristics
        o = loader.prepare(df, colmap=None)
        self.assertEqual(len(o), 1)
        self.assertEqual(o["platform_product_id"].iloc[0], "SKU123")
        self.assertEqual(o["name"].iloc[0], "Dove Deep Moisture Shampoo 340 ml")
        self.assertEqual(o["brand"].iloc[0], "Dove")
        self.assertEqual(o["price"].iloc[0], 299.0)

    def test_adaptive_weighting_formula(self):
        """Verifies adaptive weighting formula dynamically scales when attributes (e.g. size/variant) are absent."""
        # Product without size or variant (e.g. general item)
        src = {"name_clean": "oxford english dictionary", "brand": "oxford", "size_base": None, "pack_count": 1, "variant": "", "category_l1": "books"}
        cand = {"canonical_name": "oxford english dictionary", "brand": "oxford", "size_base": None, "pack_count": 1, "variant": "", "category_l1": "books"}
        w = CFG["weights"]
        score, b_sim, sz_sim = match.compute_match_score(src, cand, w)
        # Should be a perfect 1.0 because all present attributes match and weights were normalized
        self.assertEqual(score, 1.0)



if __name__ == "__main__":
    unittest.main(verbosity=2)
