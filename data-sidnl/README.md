# SIDNL Pipeline v2 - Production Matching & Analytics

```
    static files ──┐                                  ┌─ vocabulary in DB (ref_* tables, editable in Supabase)
                   ├─> loader.load_df ─> bronze/offers ─> normalize (parallel, SKIP LOCKED) ─> match (advisory lock)
    real-time POST ┘   (one write path)                 └─ dynamic learning: brands from data + titles, noise suggestions
```

## Description & Attribute Matching (No Barcodes Required)
In e-commerce, barcodes (GTIN/EAN/UPC) are frequently missing, unreliable, or stripped by platforms. The pipeline is designed to work **100% on product descriptions and attributes** without depending on barcodes.

Matching is executed using **3 core checks** directly from the workflow blueprint:

```
                          Incoming Product Listing
                                    │
                                    ▼
       ┌─────────────────────────────────────────────────────────┐
       │ Check 1: Text Match (RapidFuzz / Lexical)               │
       │  • Product Name Similarity (35%)                        │
       │  • Brand Similarity (25%)                               │
       └────────────────────────────┬────────────────────────────┘
                                    ▼
       ┌─────────────────────────────────────────────────────────┐
       │ Check 2: Meaning / Semantic Match                       │
       │  • Quantity & Pack Size Agreement (20%)                 │
       │  • Variant & Synonym Agreement (15%)                    │
       │  • Category L1/L2/L3 Taxonomy Alignment (5%)            │
       └────────────────────────────┬────────────────────────────┘
                                    ▼
       ┌─────────────────────────────────────────────────────────┐
       │ Check 3: Strict Safety Rules (Inspector Checklist)       │
       │  • Size Mismatch > 5% FAIL (500 ml != 1 L)              │
       │  • Pack Count Difference FAIL (1-pack != 6-pack)        │
       │  • Brand Conflict FAIL (Dove != Pantene)                │
       │  • Opposing Variant FAIL (Diet != Classic)              │
       └────────────────────────────┬────────────────────────────┘
                                    ▼
                          Three-Way Decision
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
   Score >= 0.90              0.75 <= Score < 0.90         Score < 0.75
  & Rules Passed             or Strict Rule Conflict      or No Candidates
        │                           │                           │
        ▼                           ▼                           ▼
   Auto-Accept                 Manual Review                New Master
    (MAPPED)                 (PENDING_REVIEW)               (UNMAPPED)
```

## Why Brands Are NOT Hardcoded
Catalogs contain tens of thousands of brands across categories (FMCG, electronics, beauty, fashion). Hardcoding brands in YAML is completely unscalable.

The pipeline uses **Automated Dynamic Brand Discovery**:
1. **Metadata Ingestion**: Brands provided in platform feeds (Blinkit, Zepto, Amazon, Flipkart, etc.) are cleaned of corporate suffixes (`Pvt Ltd`, `LLC`, `Corp`), stripped of punctuation (`Lay's` -> `lays`), and registered automatically into the database.
2. **Title Extraction**: When platform feeds omit the brand or provide non-descriptive values (`"N/A"`, `"Generic"`, `"None"`), the system extracts the brand from the leading tokens of the product name (e.g., `"Dove Intense Repair Hair Shampoo"` -> `"dove"`).
3. **In-Memory Dynamic Registration**: The normalizer registers discovered brands dynamically in O(1) in-memory dictionaries, maintaining >40,000 rows/sec per core regardless of catalog size.
4. **Fuzzy Brand Matching**: The match engine compares brands using token canonicalization and fuzzy similarity rather than rigid string equality.

## First-time setup
```bash
pip install -r requirements.txt
export SUPABASE_DB_URL='postgresql://...'      # Supabase > Connect > SESSION pooler
python -m sidnl.cli migrate                    # applies sql/001, sql/002, sql/003
python -m sidnl.cli seed-rules                 # seeds physical units & noise words
python -m unittest discover -s tests
```

## Static Data (Batch Ingestion)
Drop files into `landing/<platform>/` (supports `.parquet`, `.csv`, `.tsv`, `.jsonl`, `.csv.gz`).
```bash
python -m sidnl.cli daily                      # batch load, normalize, and match
python -m sidnl.cli ingest --platform blinkit --path data.parquet
```

## Real-Time Data (Streaming)
Crash-safe HTTP endpoint with durable fsync spooling (`.part` -> `.ndjson`):
```bash
python -m sidnl.cli live                       # runs receiver, micro-batch loader, and matcher
```
Send updates:
```bash
curl -X POST localhost:8080/ingest/blinkit -H "X-Sidnl-Token: $SIDNL_INGEST_TOKEN" \
     -d '[{"product_id":"123","name":"Dove Repair Shampoo 340ml","brand":"Dove","price":"299","in_stock":"1"}]'
```

## Silver layer (brand-scoped star schema)
Bronze `public.*` -> `silver.*` -> gold views. Docs and ERD: `docs/silver/SILVER_SCHEMA.md`.
```bash
python -m sidnl.cli silver-apply
python -m sidnl.cli silver-test
python -m sidnl.cli silver-refresh --brand "mr munchies"
python -m sidnl.cli silver-report
```
Silver SQL lives in `sql/silver/` and is applied by `silver-apply` (not by `migrate`, which only globs `sql/*.sql`).
