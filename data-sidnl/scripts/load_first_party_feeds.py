"""
scripts/load_first_party_feeds.py
Loads the Zepto seller-portal first-party exports into dash.fp_* tables.

Files (all looked up in --dir, default ~/Downloads):
  SALES_OVERVIEW_*.csv   -> dash.fp_sales_daily (+ dash.fp_sku, dash.fp_sku_name)
  GRN_*.csv              -> dash.fp_grn_line
  PO_*.csv               -> dash.fp_po (header) + dash.fp_po_line
  report_*.xlsx          -> dash.fp_ad_wallet_txn (TransactionID sheets) /
                            dash.fp_ad_page_perf (PageName sheets)

Idempotent: every table has a natural primary key and rows go in with
ON CONFLICT DO NOTHING, so copies of the same export (or overlapping exports)
cannot double-count. Exact duplicate rows inside a file are dropped first.

Connection: DIRECT_URL from data-sidnl/.env (admin session-pooler URL).
Never prints the URL or password. Pure-Python driver (pg8000).

Usage:
    python scripts/load_first_party_feeds.py [--dir DIR] [--dry-run]
"""
from __future__ import annotations

import argparse
import glob
import io
import json
import os
import ssl
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

import pandas as pd
import pg8000.dbapi

ROOT = Path(__file__).resolve().parent.parent            # data-sidnl/
BRAND_NAME = "Mr Munchies"                                # dash.brand_registry.brand_name


# --------------------------------------------------------------------------- env / connection
def read_env_var(name: str) -> str:
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith(name + "="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit(f"{name} not found in {ROOT / '.env'}")


def connect():
    u = urlsplit(read_env_var("DIRECT_URL"))
    # Always verify the server certificate. Uses the OS trust store, plus the Supabase CA file if one is
    # configured (ECOM_DATABASE_SSL_CA_FILE) or present at data-sidnl/certs/supabase-ca-2021.crt.
    ctx = ssl.create_default_context()
    ca = os.environ.get("SUPABASE_CA_FILE") or ROOT / "certs" / "supabase-ca-2021.crt"
    if Path(ca).exists():
        ctx.load_verify_locations(cafile=str(ca))
    return pg8000.dbapi.connect(
        user=unquote(u.username), password=unquote(u.password), host=u.hostname,
        port=u.port or 5432, database=u.path.lstrip("/") or "postgres", ssl_context=ctx, timeout=600,
    )


# --------------------------------------------------------------------------- DDL
DDL = [
    """create table if not exists dash.fp_sku (
        sku_id uuid primary key, brand_name text not null, manufacturer_id uuid,
        manufacturer_name text, sku_category text)""",
    """create table if not exists dash.fp_sku_name (
        sku_id uuid not null, sku_name text not null, primary key (sku_id, sku_name))""",
    """create table if not exists dash.fp_sales_daily (
        sales_date date not null, sku_id uuid not null, city text not null,
        quantity int, gmv numeric(14,2), primary key (sales_date, sku_id, city))""",
    "create index if not exists fp_sales_daily_sku_idx on dash.fp_sales_daily (sku_id, sales_date)",
    """create table if not exists dash.fp_po (
        po_no text primary key, po_date timestamp, status text, vendor_code text, vendor_name text,
        po_amount numeric(14,2), del_location text, created_by text, po_expiry_at timestamp)""",
    """create table if not exists dash.fp_po_line (
        po_no text not null, sku_id uuid not null, line_no int, sku_code text, sku_desc text, brand text,
        ean text, hsn text, cgst_pct numeric, sgst_pct numeric, igst_pct numeric, cess_pct numeric,
        mrp numeric(12,2), qty int, unit_base_cost numeric(12,4), landing_cost numeric(12,4),
        total_amount numeric(14,2), asn_qty int, grn_qty int, primary key (po_no, sku_id))""",
    """create table if not exists dash.fp_grn_line (
        po_code text not null, sku_id uuid not null, grn_code text not null, batch_id uuid,
        po_created_at timestamptz, po_created_by text, po_approved_at timestamptz, po_expiry_at timestamptz,
        po_delivery_at timestamptz, po_cancelled_at timestamptz, po_status int, po_status_desc text,
        po_type text, vendor_code text, vendor_name text, to_store_code text, to_store_name text,
        product_name text, brand_name text, manufacturer_name text, category text, sub_category text,
        po_qty int, asn_qty int, grn_qty int, asn_no text, external_asn_no text, vin_po text,
        asn_date timestamptz, asn_status text, asn_confirmed_at timestamptz, grn_date timestamptz,
        invoice_no text, invoice_amount numeric(14,2), mrp numeric(12,2), margin_pct numeric,
        cost_price numeric(12,4), margin_amount numeric(12,4), tax_pct numeric, cgst_pct numeric,
        igst_pct numeric, sgst_pct numeric, cess_pct numeric, absolute_cess numeric,
        absolute_cess_total numeric, cgst_value numeric, sgst_value numeric, igst_value numeric,
        cess_value numeric, cost_price_ex_tax numeric, tasn_cost numeric(14,4), total_amount numeric(14,2),
        entity_code text, remarks text, primary key (po_code, sku_id, grn_code))""",
    """create table if not exists dash.fp_ad_wallet_txn (
        transaction_id uuid primary key, source_brand_id uuid, txn_type text not null, subtype text,
        description text, meta jsonb, created_at timestamptz not null, updated_at timestamptz,
        amount numeric(14,2) not null, currency text, status text, created_by text)""",
    """create table if not exists dash.fp_ad_page_perf (
        snapshot_label text not null, page_name text not null, source_brand_id uuid, atc bigint, clicks bigint,
        cpc numeric, cpm numeric, impressions bigint, orders bigint, other_skus bigint, revenue numeric,
        roas numeric, robas numeric, same_skus bigint, spend numeric, primary key (snapshot_label, page_name))""",
]
TABLES = ["fp_sku", "fp_sku_name", "fp_sales_daily", "fp_po", "fp_po_line", "fp_grn_line",
          "fp_ad_wallet_txn", "fp_ad_page_perf", "fp_load_log"]


def ensure_schema(cur):
    for stmt in DDL:
        cur.execute(stmt)
    cur.execute("""create table if not exists dash.fp_load_log (
        file_name text primary key, loaded_at timestamptz not null default now(), row_count int not null)""")
    for t in TABLES:   # the project requires brand_id on every dash table; add if not auto-added
        cur.execute(f"alter table dash.{t} add column if not exists brand_id uuid")


# --------------------------------------------------------------------------- bulk helper
def bulk_insert(cur, table: str, df: pd.DataFrame, cols: list[tuple[str, str]], brand_id: str, conflict: str):
    """Stage df (all-text) via COPY, then INSERT .. SELECT with casts ON CONFLICT DO NOTHING."""
    cur.execute("create temp table _stage (" + ", ".join(f'"{c}" text' for c, _ in cols) + ") on commit drop")
    buf = io.BytesIO(df[[c for c, _ in cols]].to_csv(index=False, header=False).encode("utf-8"))
    cur.execute("copy _stage from stdin with (format csv)", stream=buf)
    names = ", ".join(f'"{c}"' for c, _ in cols)
    sel = ", ".join(f'nullif("{c}", \'\')::{t}' for c, t in cols)
    cur.execute(f"insert into dash.{table} ({names}, brand_id) select {sel}, '{brand_id}'::uuid from _stage "
                f"on conflict ({conflict}) do nothing")
    n = cur.rowcount
    cur.execute("drop table _stage")
    return n


def log_file(cur, name: str, rows: int, brand_id: str):
    cur.execute("insert into dash.fp_load_log (file_name, row_count, brand_id) values (%s, %s, %s) "
                "on conflict (file_name) do update set row_count = excluded.row_count, loaded_at = now()",
                (name, rows, brand_id))


def ts(series: pd.Series, utc: bool = False) -> pd.Series:
    s = pd.to_datetime(series, errors="coerce", utc=utc, format="mixed")
    s = s.where(s.dt.year >= 2000)          # 0001-01-01 placeholders -> NULL
    return s.dt.strftime("%Y-%m-%d %H:%M:%S%z" if utc else "%Y-%m-%d %H:%M:%S")


# --------------------------------------------------------------------------- loaders
def load_sales(cur, files, brand_id, dry):
    df = pd.concat([pd.read_csv(f, dtype=str) for f in files], ignore_index=True)
    df["sku_id"] = df["SKU ID"].str.lower()
    df["sales_date"] = pd.to_datetime(df["Sales Date"], format="%d-%m-%Y").dt.strftime("%Y-%m-%d")
    fact = df.rename(columns={"City": "city", "Quantity": "quantity", "GMV": "gmv"})
    fact = fact[["sales_date", "sku_id", "city", "quantity", "gmv"]].drop_duplicates()
    assert not fact.duplicated(["sales_date", "sku_id", "city"]).any(), "conflicting duplicate sales keys"
    q = pd.to_numeric(fact["quantity"]); g = pd.to_numeric(fact["gmv"])
    exp = dict(rows=len(fact), qty=int(q.sum()), gmv=float(g.sum()))
    sku = df.drop_duplicates("sku_id")[["sku_id", "Brand Name", "Manufacturer ID", "Manufacturer Name", "SKU Category"]]
    sku.columns = ["sku_id", "brand_name", "manufacturer_id", "manufacturer_name", "sku_category"]
    names = df[["sku_id", "SKU Name"]].drop_duplicates().rename(columns={"SKU Name": "sku_name"})
    names["sku_name"] = names["sku_name"].str.replace(r"\s+", " ", regex=True)
    names = names.drop_duplicates()
    print(f"sales: {exp}  skus={len(sku)} sku_names={len(names)}")
    if dry:
        return exp
    bulk_insert(cur, "fp_sku", sku, [("sku_id", "uuid"), ("brand_name", "text"), ("manufacturer_id", "uuid"),
                                     ("manufacturer_name", "text"), ("sku_category", "text")], brand_id, "sku_id")
    bulk_insert(cur, "fp_sku_name", names, [("sku_id", "uuid"), ("sku_name", "text")], brand_id, "sku_id, sku_name")
    bulk_insert(cur, "fp_sales_daily", fact, [("sales_date", "date"), ("sku_id", "uuid"), ("city", "text"),
                                              ("quantity", "int"), ("gmv", "numeric")], brand_id, "sales_date, sku_id, city")
    for f in files:
        log_file(cur, os.path.basename(f), len(pd.read_csv(f, dtype=str)), brand_id)
    return exp


def load_po(cur, files, brand_id, dry):
    po = pd.concat([pd.read_csv(f, dtype=str) for f in files], ignore_index=True).drop_duplicates()
    po["sku_id"] = po["SKU"].str.lower()
    for c in ("PO Date", "PO Expiry Date"):
        po[c] = pd.to_datetime(po[c], format="%d %b %Y %I:%M %p").dt.strftime("%Y-%m-%d %H:%M:%S")
    assert not po.duplicated(["PO No.", "sku_id"]).any()
    hdr_cols = ["PO No.", "PO Date", "Status", "Vendor Code", "Vendor Name", "PO Amount", "Del Location",
                "Created By", "PO Expiry Date"]
    hdr = po[hdr_cols].drop_duplicates()
    assert not hdr.duplicated("PO No.").any(), "PO header values differ between lines"
    hdr.columns = ["po_no", "po_date", "status", "vendor_code", "vendor_name", "po_amount", "del_location",
                   "created_by", "po_expiry_at"]
    ln = po.rename(columns={"PO No.": "po_no", "Line No": "line_no", "SKU Code": "sku_code", "SKU Desc": "sku_desc",
                            "Brand": "brand", "EAN": "ean", "HSN": "hsn", "CGST %": "cgst_pct", "SGST %": "sgst_pct",
                            "IGST %": "igst_pct", "CESS %": "cess_pct", "MRP/RSP": "mrp", "Qty": "qty",
                            "Unit Base Cost": "unit_base_cost", "Landing Cost": "landing_cost",
                            "Total Amount": "total_amount", "ASN Quantity": "asn_qty", "GRN Quantity": "grn_qty"})
    lcols = ["po_no", "sku_id", "line_no", "sku_code", "sku_desc", "brand", "ean", "hsn", "cgst_pct", "sgst_pct",
             "igst_pct", "cess_pct", "mrp", "qty", "unit_base_cost", "landing_cost", "total_amount", "asn_qty", "grn_qty"]
    ln = ln[lcols]
    exp = dict(headers=len(hdr), lines=len(ln), qty=int(pd.to_numeric(ln["qty"]).sum()),
               amount=round(float(pd.to_numeric(ln["total_amount"]).sum()), 2))
    print("po:", exp)
    if dry:
        return exp
    bulk_insert(cur, "fp_po", hdr, [("po_no", "text"), ("po_date", "timestamp"), ("status", "text"),
                ("vendor_code", "text"), ("vendor_name", "text"), ("po_amount", "numeric"), ("del_location", "text"),
                ("created_by", "text"), ("po_expiry_at", "timestamp")], brand_id, "po_no")
    types = {"line_no": "int", "qty": "int", "asn_qty": "int", "grn_qty": "int", "sku_id": "uuid"}
    numeric = {"cgst_pct", "sgst_pct", "igst_pct", "cess_pct", "mrp", "unit_base_cost", "landing_cost", "total_amount"}
    bulk_insert(cur, "fp_po_line", ln, [(c, types.get(c, "numeric" if c in numeric else "text")) for c in lcols],
                brand_id, "po_no, sku_id")
    for f in files:
        log_file(cur, os.path.basename(f), len(pd.read_csv(f, dtype=str)), brand_id)
    return exp


def load_grn(cur, files, brand_id, dry):
    g = pd.concat([pd.read_csv(f, dtype=str) for f in files], ignore_index=True).drop_duplicates()
    g["sku_id"] = g["SKU ID"].str.lower()
    assert not g.duplicated(["PO Code", "sku_id", "GRN Code"]).any(), "conflicting GRN key"
    ren = {"PO Code": "po_code", "Batch ID": "batch_id", "PO Created Date": "po_created_at",
           "PO Created By": "po_created_by", "PO Approved Date": "po_approved_at", "PO Expiry Date": "po_expiry_at",
           "PO Delivery Date": "po_delivery_at", "PO Cancelled Date": "po_cancelled_at", "PO Status": "po_status",
           "PO Status Description": "po_status_desc", "PO Type": "po_type", "Vendor Code": "vendor_code",
           "Vendor Name": "vendor_name", "To Store Code": "to_store_code", "To Store Name": "to_store_name",
           "Product Name": "product_name", "Brand Name": "brand_name", "Manufacturer Name": "manufacturer_name",
           "Category": "category", "Sub Category": "sub_category", "PO Quantity": "po_qty", "ASN Quantity": "asn_qty",
           "GRN Quantity": "grn_qty", "ASN No": "asn_no", "External ASN No": "external_asn_no", "VIN PO": "vin_po",
           "ASN Date": "asn_date", "ASN Status": "asn_status", "ASN Confirmed Date": "asn_confirmed_at",
           "GRN Date": "grn_date", "GRN Code": "grn_code", "Invoice No": "invoice_no", "Invoice Amount": "invoice_amount",
           "MRP": "mrp", "Margin": "margin_pct", "Cost Price": "cost_price", "Margin Amount": "margin_amount",
           "Tax Percentage": "tax_pct", "CGST Percentage": "cgst_pct", "IGST Percentage": "igst_pct",
           "SGST Percentage": "sgst_pct", "Cess Percentage": "cess_pct", "Absolute Cess": "absolute_cess",
           "Absolute Cess Total": "absolute_cess_total", "CGST Value": "cgst_value", "SGST Value": "sgst_value",
           "IGST Value": "igst_value", "Cess Value": "cess_value", "Cost Price Without Tax": "cost_price_ex_tax",
           "TASN Cost": "tasn_cost", "Total Amount": "total_amount", "Entity Code": "entity_code", "Remarks": "remarks"}
    g = g.rename(columns=ren)
    tcols = ["po_created_at", "po_approved_at", "po_expiry_at", "po_delivery_at", "po_cancelled_at", "asn_date",
             "asn_confirmed_at", "grn_date"]
    for c in tcols:
        g[c] = ts(g[c], utc=True)
    text = {"po_code", "po_created_by", "po_status_desc", "po_type", "vendor_code", "vendor_name", "to_store_code",
            "to_store_name", "product_name", "brand_name", "manufacturer_name", "category", "sub_category", "asn_no",
            "external_asn_no", "vin_po", "asn_status", "grn_code", "invoice_no", "entity_code", "remarks"}
    ints = {"po_status", "po_qty", "asn_qty", "grn_qty"}
    cols = []
    for c in ["po_code", "sku_id", "grn_code", "batch_id"] + [v for v in ren.values()
              if v not in ("po_code", "grn_code", "batch_id")]:
        if c in text: t = "text"
        elif c in ints: t = "int"
        elif c in tcols: t = "timestamptz"
        elif c in ("sku_id", "batch_id"): t = "uuid"
        else: t = "numeric"
        cols.append((c, t))
    g = g[[c for c, _ in cols]]
    exp = dict(rows=len(g), po_qty=int(pd.to_numeric(g["po_qty"]).sum()), grn_qty=int(pd.to_numeric(g["grn_qty"]).sum()),
               total_amount=round(float(pd.to_numeric(g["total_amount"]).sum()), 2))
    print("grn:", exp)
    if dry:
        return exp
    bulk_insert(cur, "fp_grn_line", g, cols, brand_id, "po_code, sku_id, grn_code")
    for f in files:
        log_file(cur, os.path.basename(f), len(pd.read_csv(f, dtype=str)), brand_id)
    return exp


def load_reports(cur, files, brand_id, dry):
    wallet, pages = [], []
    for f in files:
        x = pd.read_excel(f, dtype=str)
        (wallet if "TransactionID" in x.columns else pages).append((f, x))
    out = {}
    if wallet:
        w = pd.concat([x for _, x in wallet], ignore_index=True).drop_duplicates()
        assert not w.duplicated("TransactionID").any(), "conflicting wallet transaction"
        w["description"] = w["Meta"].map(lambda m: (json.loads(m).get("description") if isinstance(m, str) else None))
        w["created_at"] = ts(w["CreatedAt"], utc=True); w["updated_at"] = ts(w["UpdatedAt"], utc=True)
        w = w.rename(columns={"TransactionID": "transaction_id", "BrandID": "source_brand_id", "Type": "txn_type",
                              "Subtype": "subtype", "Meta": "meta", "Amount": "amount", "Currency": "currency",
                              "Status": "status", "CreatedBy": "created_by"})
        cols = [("transaction_id", "uuid"), ("source_brand_id", "uuid"), ("txn_type", "text"), ("subtype", "text"),
                ("description", "text"), ("meta", "jsonb"), ("created_at", "timestamptz"), ("updated_at", "timestamptz"),
                ("amount", "numeric"), ("currency", "text"), ("status", "text"), ("created_by", "text")]
        w = w[[c for c, _ in cols]]
        amt = pd.to_numeric(w["amount"])
        out["wallet"] = dict(rows=len(w), credits=float(amt[w.txn_type == "credit"].sum()),
                             debits=float(amt[w.txn_type == "debit"].sum()))
        print("wallet:", out["wallet"])
        if not dry:
            bulk_insert(cur, "fp_ad_wallet_txn", w, cols, brand_id, "transaction_id")
            for f, x in wallet:
                log_file(cur, os.path.basename(f), len(x), brand_id)
    for f, p in pages:
        label = os.path.splitext(os.path.basename(f))[0]
        p = p.drop_duplicates()
        p["snapshot_label"] = label
        p = p.rename(columns={"PageName": "page_name", "BrandID": "source_brand_id", "Atc": "atc", "Clicks": "clicks",
                              "Cpc": "cpc", "Cpm": "cpm", "Impressions": "impressions", "Orders": "orders",
                              "Other_skus": "other_skus", "Revenue": "revenue", "Roas": "roas", "Robas": "robas",
                              "Same_skus": "same_skus", "Spend": "spend"})
        ints = {"atc", "clicks", "impressions", "orders", "other_skus", "same_skus"}
        cols = [("snapshot_label", "text"), ("page_name", "text"), ("source_brand_id", "uuid")] + \
               [(c, "bigint" if c in ints else "numeric") for c in
                ["atc", "clicks", "cpc", "cpm", "impressions", "orders", "other_skus", "revenue", "roas", "robas",
                 "same_skus", "spend"]]
        p = p[[c for c, _ in cols]]
        # values like 3.768757e+06 -> plain numbers
        for c, t in cols[3:]:
            p[c] = pd.to_numeric(p[c]).map(lambda v: format(v, "f").rstrip("0").rstrip(".") if v == v else "")
        out["pages"] = dict(rows=len(p), impressions=int(pd.to_numeric(p["impressions"]).sum()),
                            spend=float(pd.to_numeric(p["spend"]).sum()))
        print("page perf:", out["pages"])
        if not dry:
            bulk_insert(cur, "fp_ad_page_perf", p, cols, brand_id, "snapshot_label, page_name")
            log_file(cur, os.path.basename(f), len(p), brand_id)
    return out


# --------------------------------------------------------------------------- verification
def verify(cur, exp):
    def one(sql):
        cur.execute(sql); return cur.fetchone()
    checks = []
    r = one("select count(*), coalesce(sum(quantity),0), coalesce(sum(gmv),0) from dash.fp_sales_daily")
    checks.append(("sales rows", r[0], exp["sales"]["rows"])); checks.append(("sales qty", int(r[1]), exp["sales"]["qty"]))
    checks.append(("sales gmv", float(r[2]), exp["sales"]["gmv"]))
    r = one("select count(*) from dash.fp_po"); checks.append(("po headers", r[0], exp["po"]["headers"]))
    r = one("select count(*), coalesce(sum(qty),0), coalesce(sum(total_amount),0) from dash.fp_po_line")
    checks += [("po lines", r[0], exp["po"]["lines"]), ("po qty", int(r[1]), exp["po"]["qty"]),
               ("po amount", round(float(r[2]), 2), exp["po"]["amount"])]
    r = one("select count(*), coalesce(sum(po_qty),0), coalesce(sum(grn_qty),0), coalesce(sum(total_amount),0) from dash.fp_grn_line")
    checks += [("grn rows", r[0], exp["grn"]["rows"]), ("grn po_qty", int(r[1]), exp["grn"]["po_qty"]),
               ("grn grn_qty", int(r[2]), exp["grn"]["grn_qty"]), ("grn amount", round(float(r[3]), 2), exp["grn"]["total_amount"])]
    r = one("select count(*), coalesce(sum(amount) filter (where txn_type='credit'),0), coalesce(sum(amount) filter (where txn_type='debit'),0) from dash.fp_ad_wallet_txn")
    checks += [("wallet rows", r[0], exp["reports"]["wallet"]["rows"]),
               ("wallet credits", float(r[1]), exp["reports"]["wallet"]["credits"]),
               ("wallet debits", float(r[2]), exp["reports"]["wallet"]["debits"])]
    r = one("select count(*), coalesce(sum(impressions),0), coalesce(sum(spend),0) from dash.fp_ad_page_perf")
    checks += [("page rows", r[0], exp["reports"]["pages"]["rows"]), ("page impressions", int(r[1]), exp["reports"]["pages"]["impressions"]),
               ("page spend", float(r[2]), exp["reports"]["pages"]["spend"])]
    bad = 0
    for name, got, want in checks:
        ok = abs(got - want) < 0.01 if isinstance(want, float) else got == want
        bad += not ok
        print(f"  {'OK ' if ok else 'BAD'} {name}: db={got} source={want}")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(Path.home() / "Downloads"))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    pick = lambda pat: sorted(glob.glob(os.path.join(a.dir, pat)))
    # one copy per distinct content (Windows "(1)" copies and identical re-exports are skipped by hash)
    def uniq(paths):
        seen, out = set(), []
        for p in paths:
            h = pd.util.hash_pandas_object(pd.read_csv(p, dtype=str, keep_default_na=False)).sum() if p.endswith(".csv") \
                else os.path.getsize(p)
            if (h, os.path.getsize(p)) not in seen:
                seen.add((h, os.path.getsize(p))); out.append(p)
        return out
    sales, grn, po, rep = (uniq(pick("SALES_OVERVIEW_*.csv")), uniq(pick("GRN_*.csv")),
                           uniq(pick("PO_*.csv")), uniq(pick("report_*.xlsx")))
    print(f"files: sales={len(sales)} grn={len(grn)} po={len(po)} reports={len(rep)}")
    conn = connect(); cur = conn.cursor()
    cur.execute("select brand_id::text from dash.brand_registry where brand_name = %s", (BRAND_NAME,))
    row = cur.fetchone()
    if not row:
        raise SystemExit(f"{BRAND_NAME} not in dash.brand_registry")
    brand_id = row[0]
    if not a.dry_run:
        ensure_schema(cur); conn.commit()
    exp = {}
    exp["sales"] = load_sales(cur, sales, brand_id, a.dry_run);
    if not a.dry_run: conn.commit()
    exp["po"] = load_po(cur, po, brand_id, a.dry_run)
    if not a.dry_run: conn.commit()
    exp["grn"] = load_grn(cur, grn, brand_id, a.dry_run)
    if not a.dry_run: conn.commit()
    exp["reports"] = load_reports(cur, rep, brand_id, a.dry_run)
    if not a.dry_run:
        conn.commit()
        for t in TABLES:   # enforce brand scoping now that every row has a brand_id
            cur.execute(f"alter table dash.{t} alter column brand_id set not null")
        conn.commit()
        bad = verify(cur, exp)
        print("VERIFY:", "all checks passed" if not bad else f"{bad} check(s) FAILED")
        sys.exit(1 if bad else 0)
    conn.rollback()


if __name__ == "__main__":
    main()
