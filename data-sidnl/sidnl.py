"""SIDNL command line: check and operate the pipeline that runs inside Supabase.

The pipeline itself runs in the database (pg_cron jobs, see README.md). This tool only inspects it, triggers it by hand,
and keeps the repo's schema files identical to the live database.

    python sidnl.py report                 health, data quality, freshness, reconciliation, dead letters
    python sidnl.py run [--force]          run bronze -> silver now (what cron does every minute)
    python sidnl.py refresh --brand NAME   reload one client brand
    python sidnl.py test                   in-database self-tests (parser, matcher, quality checks)
    python sidnl.py export-schema          regenerate sql/01..03 and sql/manifest.csv from the live database
    python sidnl.py verify                 fail if the repo's sql files differ from the live database

Connection: environment variable SUPABASE_DB_URL (Supabase > Connect > Session pooler). Never put it in a file.
"""
import argparse
import csv
import io
import json
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SQL_DIR = ROOT / "sql"
SCHEMA_FILES = {
    "tables": SQL_DIR / "01_tables.sql",
    "functions": SQL_DIR / "02_functions.sql",
    "views": SQL_DIR / "03_views_jobs_config.sql",
}
MANIFEST = SQL_DIR / "manifest.csv"


# --------------------------------------------------------------------------------------------------------------------
# connection
# --------------------------------------------------------------------------------------------------------------------
def connect():
    try:
        url = os.environ["SUPABASE_DB_URL"]
    except KeyError:
        raise SystemExit("Set SUPABASE_DB_URL (Supabase > Connect > Session pooler). Do not put it in a file.")
    try:
        import psycopg
        conn = psycopg.connect(url, prepare_threshold=None, autocommit=False, application_name="sidnl")
    except ImportError:  # psycopg binary blocked on some machines; psycopg2 works the same for this tool
        import psycopg2
        conn = psycopg2.connect(url, application_name="sidnl")
    with conn.cursor() as cur:
        cur.execute("set statement_timeout = 0")
    conn.commit()
    return conn


def one(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()[0]


def rows(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        cols = [c[0] for c in cur.description]
        return cols, cur.fetchall()


def show(title, cols, data):
    print(f"-- {title}")
    for r in data:
        print("  " + " | ".join(f"{c}={v}" for c, v in zip(cols, r)))


# --------------------------------------------------------------------------------------------------------------------
# operations
# --------------------------------------------------------------------------------------------------------------------
def cmd_report(conn, _a):
    cols, data = rows(conn, "select * from ops.v_silver_health")
    print("-- silver health")
    for k, v in zip(cols, data[0]):
        print(f"  {k:32s} {v}")
    show("gold refresh", *rows(conn, "select table_name, last_refreshed_at, age_minutes, is_stale, refresh_failing, "
                                     "needs_attention from dash.v_refresh_status order by 1"))
    show("platform freshness (bronze)", *rows(conn, "select platform, status, hours_since_last_data, stale_sources, "
                                                    "never_seen_sources from dash.v_platform_freshness order by 1"))
    show("reconciliation (bronze -> silver -> dash)", *rows(conn, "select check_name, run_at, status, rows_checked, "
                                                                  "mismatches from ops.v_reconciliation_latest order by 1"))
    show("dead letters", *rows(conn, "select platform, l1_id, l2_id, status, rows, latest_reason "
                                     "from ops.v_dead_letter_summary order by 1, 2, 3, 4"))
    show("cron jobs", *rows(conn, "select jobname, active, runs_24h, failures_24h, consecutive_failures "
                                  "from ops.v_cron_health order by 1"))


def cmd_run(conn, a):
    res = one(conn, "select silver.run_pipeline(%s, 'manual')", (a.force,))
    conn.commit()
    res = res if isinstance(res, dict) else json.loads(res)
    print(json.dumps({k: res.get(k) for k in ("status", "mode", "run_id", "gold_status")}, indent=2, default=str))


def cmd_refresh(conn, a):
    stats = one(conn, "select silver.refresh_brand(%s)", (a.brand,))
    conn.commit()
    print(json.dumps(stats, indent=2, default=str))


def cmd_test(conn, _a):
    print(one(conn, "select silver.selftest_parser()"))
    bad = one(conn, "select count(*) from silver.selftest_matcher() t where not t.ok")
    print(f"matcher self-test failures: {bad}")
    failed = one(conn, "select coalesce(json_agg(t.check_name), '[]') from silver.quality_checks() t where not t.ok")
    print(f"quality checks failed: {failed}")
    conn.rollback()
    if bad or (failed not in ([], "[]")):
        raise SystemExit(1)


# --------------------------------------------------------------------------------------------------------------------
# schema export: the repo's sql/01..03 are generated from the live catalog, never written by hand
# --------------------------------------------------------------------------------------------------------------------
HEADER = """-- data-sidnl schema, part {n} of 3: {what}
-- GENERATED from the live Supabase database by `python sidnl.py export-schema`. Do not edit by hand.
-- Documentation and recovery baseline only: the objects already exist in production; never apply this file there.
-- Recovery on an empty database: apply 01, 02, 03 in order, then run `select silver.run_pipeline(true, 'rebuild')`
-- to rebuild silver from bronze, then `select silver.run_gold_pending()` to rebuild dash.
"""

EXPORT_SQL = r"""
with nsp as (
    select oid, nspname from pg_namespace where nspname in ('silver', 'dash', 'ops')
), rel as (
    select c.oid, n.nspname, c.relname, c.relkind, c.reloptions, c.relrowsecurity, format('%I.%I', n.nspname, c.relname) as fq
      from pg_class c join nsp n on n.oid = c.relnamespace
), deferred_default as (   -- defaults that call our own functions are set after the functions exist (part 2)
    select ad.adrelid, ad.adnum
      from pg_attrdef ad join rel r on r.oid = ad.adrelid
     where pg_get_expr(ad.adbin, ad.adrelid) ~ '(silver|dash|ops)\.[a-z_]+\('
), fn as (   -- our functions: schemas silver / dash / ops, plus the public endpoint function(s) named sidnl_*
    select p.oid, p.proname, p.proacl, n.nspname,
           n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where p.prokind = 'f'
       and (n.nspname in ('silver', 'dash', 'ops') or (n.nspname = 'public' and p.proname like 'sidnl\_%'))
), parts as (
    -- ===================== part 1: extensions, schemas, types, sequences, tables, constraints, indexes, RLS, comments
    select 'tables' as part, 1 as sec, '' as k,
           E'create schema if not exists silver;\ncreate schema if not exists dash;\ncreate schema if not exists ops;' as txt
    union all
    select 'tables', 1, 'ext ' || e.extname, format('create extension if not exists %I;', e.extname)
      from pg_extension e where e.extname in ('pg_trgm', 'pg_cron', 'pg_net', 'pgcrypto', 'uuid-ossp', 'supabase_vault')
    union all
    select 'tables', 2, format('%I.%I', n.nspname, t.typname),
           format('create type %I.%I as (%s);', n.nspname, t.typname,
                  (select string_agg(format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod)), ', ' order by a.attnum)
                     from pg_attribute a where a.attrelid = t.typrelid and a.attnum > 0 and not a.attisdropped))
      from pg_type t join nsp n on n.oid = t.typnamespace join pg_class c on c.oid = t.typrelid
     where c.relkind = 'c'
    union all
    select 'tables', 3, r.fq,
           format('create sequence if not exists %s as %s increment by %s minvalue %s maxvalue %s start with %s cache %s%s;',
                  r.fq, format_type(s.seqtypid, null), s.seqincrement, s.seqmin, s.seqmax, s.seqstart, s.seqcache,
                  case when s.seqcycle then ' cycle' else '' end)
      from pg_sequence s join rel r on r.oid = s.seqrelid
     where not exists (select 1 from pg_depend d where d.objid = s.seqrelid and d.classid = 'pg_class'::regclass and d.deptype = 'i')
    union all
    select 'tables', 4, r.fq,
           format(E'create table if not exists %s (\n%s\n)%s;', r.fq,
                  (select string_agg('    ' || format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod))
                          || case a.attidentity when 'a' then ' generated always as identity'
                                                when 'd' then ' generated by default as identity' else '' end
                          || case when a.attgenerated = 's' then ' generated always as (' || pg_get_expr(ad.adbin, ad.adrelid) || ') stored'
                                  when ad.adbin is not null and dd.adrelid is null then ' default ' || pg_get_expr(ad.adbin, ad.adrelid)
                                  else '' end
                          || case when a.attnotnull then ' not null' else '' end,
                          E',\n' order by a.attnum)
                     from pg_attribute a
                     left join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
                     left join deferred_default dd on dd.adrelid = a.attrelid and dd.adnum = a.attnum
                    where a.attrelid = r.oid and a.attnum > 0 and not a.attisdropped),
                  case when r.reloptions is not null then ' with (' || array_to_string(r.reloptions, ', ') || ')' else '' end)
      from rel r where r.relkind = 'r'
    union all
    select 'tables', 5, r.fq || ' ' || con.conname,
           format('alter table %s add constraint %I %s;', r.fq, con.conname, pg_get_constraintdef(con.oid))
      from pg_constraint con join rel r on r.oid = con.conrelid
     where con.contype in ('p', 'u', 'c', 'x') and r.relkind = 'r'
    union all
    select 'tables', 6, r.fq || ' ' || con.conname,
           format('alter table %s add constraint %I %s;', r.fq, con.conname, pg_get_constraintdef(con.oid))
      from pg_constraint con join rel r on r.oid = con.conrelid
     where con.contype = 'f'
    union all
    select 'tables', 7, r.fq || ' ' || ci.relname, pg_get_indexdef(i.indexrelid) || ';'
      from pg_index i join pg_class ci on ci.oid = i.indexrelid join rel r on r.oid = i.indrelid
     where r.relkind = 'r'
       and not exists (select 1 from pg_constraint con where con.conindid = i.indexrelid and con.contype in ('p', 'u', 'x'))
    union all
    select 'tables', 8, rs.fq, format('alter sequence %s owned by %s.%I;', rs.fq, rt.fq, a.attname)
      from pg_depend d
      join rel rs on rs.oid = d.objid and rs.relkind = 'S'
      join rel rt on rt.oid = d.refobjid
      join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
     where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype = 'a'
    union all
    select 'tables', 9, r.fq, format('alter table %s enable row level security;', r.fq)
      from rel r where r.relkind = 'r' and r.relrowsecurity
    union all
    select 'tables', 10, r.fq || ' ' || coalesce(a.attname, ''),
           case when d.objsubid = 0 then format('comment on table %s is %L;', r.fq, d.description)
                else format('comment on column %s.%I is %L;', r.fq, a.attname, d.description) end
      from pg_description d
      join rel r on r.oid = d.objoid and d.classoid = 'pg_class'::regclass and r.relkind = 'r'
      left join pg_attribute a on a.attrelid = d.objoid and a.attnum = d.objsubid and d.objsubid > 0
    -- ===================== part 2: functions, then defaults that call them ========================================
    union all
    select 'functions', 1, '', 'set check_function_bodies = off;'
    union all
    select 'functions', 2, f.sig, pg_get_functiondef(f.oid) || ';' from fn f
    union all
    select 'functions', 3, f.sig, format('comment on function %s is %L;', f.sig, d.description)
      from fn f join pg_description d on d.objoid = f.oid and d.classoid = 'pg_proc'::regclass
    union all
    select 'functions', 4, r.fq || ' ' || a.attname,
           format('alter table %s alter column %I set default %s;', r.fq, a.attname, pg_get_expr(ad.adbin, ad.adrelid))
      from deferred_default dd
      join pg_attrdef ad on ad.adrelid = dd.adrelid and ad.adnum = dd.adnum
      join rel r on r.oid = dd.adrelid
      join pg_attribute a on a.attrelid = dd.adrelid and a.attnum = dd.adnum
    union all
    -- function permissions: revoke the PUBLIC default where it was removed, then grant to the roles that have access
    select 'functions', 5, f.sig,
           case when not exists (select 1 from aclexplode(f.proacl) x where x.grantee = 0)
                then format('revoke all on function %s from public;', f.sig) else '' end
           || coalesce((select string_agg(format(E'\ndo $g$ begin if exists (select 1 from pg_roles where rolname = %L) then grant execute on function %s to %I; end if; end $g$;',
                                                 x.grantee::regrole::text, f.sig, x.grantee::regrole::text), '' order by x.grantee::regrole::text)
                          from aclexplode(f.proacl) x
                         where x.grantee <> 0 and x.grantee::regrole::text <> 'postgres'), '')
      from fn f where f.proacl is not null
    -- ===================== part 3: views (dependency order), grants, configuration rows, cron jobs =================
    union all
    select 'views', 1, lpad(r.oid::text, 12, '0'),
           format(E'create or replace view %s%s as\n%s', r.fq,
                  case when r.reloptions is not null then ' with (' || array_to_string(r.reloptions, ', ') || ')' else '' end,
                  pg_get_viewdef(r.oid))
      from rel r where r.relkind = 'v'
    union all
    select 'views', 2, r.fq, format('comment on view %s is %L;', r.fq, d.description)
      from pg_description d join rel r on r.oid = d.objoid and d.classoid = 'pg_class'::regclass and r.relkind = 'v' and d.objsubid = 0
    union all
    select 'views', 3, g.grantee,
           format(E'do $g$ begin\n  if exists (select 1 from pg_roles where rolname = %L) then\n%s\n  end if;\nend $g$;', g.grantee,
                  string_agg(format('    grant %s on %I.%I to %I;', g.privilege_type, g.table_schema, g.table_name, g.grantee),
                             E'\n' order by g.table_schema, g.table_name, g.privilege_type))
      from information_schema.role_table_grants g
     where g.table_schema in ('silver', 'dash', 'ops') and g.grantee not in ('postgres', 'supabase_admin')
     group by g.grantee
    union all
    select 'views', 4, n.nspname || ' ' || x.grantee::regrole::text,
           format(E'do $g$ begin\n  if exists (select 1 from pg_roles where rolname = %L) then\n    grant %s on schema %I to %I;\n  end if;\nend $g$;',
                  x.grantee::regrole::text, x.privilege_type, n.nspname, x.grantee::regrole::text)
      from nsp n cross join lateral aclexplode((select nspacl from pg_namespace where oid = n.oid)) x
     where x.grantee <> 0 and x.grantee::regrole::text not in ('postgres', 'supabase_admin')
    union all
    select 'views', 5, c.t, format('insert into %s select * from json_populate_recordset(null::%s, %L) on conflict do nothing;', c.t, c.t, c.j)
      from (values
            ('silver.sidnl_config',         (select json_agg(t order by t.key) from silver.sidnl_config t)),
            ('silver.freshness_policy',     (select json_agg(t order by t.source_type) from silver.freshness_policy t)),
            ('silver.dim_platform',         (select json_agg(t order by t.platform) from silver.dim_platform t)),
            ('silver.brand_scope',          (select json_agg(t order by t.brand_key) from silver.brand_scope t where t.is_enabled)),
            ('silver.ref_noise_word',       (select json_agg(t order by t::text) from silver.ref_noise_word t)),
            ('silver.ref_variant_synonym',  (select json_agg(t order by t::text) from silver.ref_variant_synonym t)),
            ('dash.cfg_threshold',          (select json_agg(t order by t.key) from dash.cfg_threshold t)),
            ('dash.cfg_sku',                (select json_agg(t order by t::text) from dash.cfg_sku t)),
            ('ops.freshness_override',      (select json_agg(t order by t.platform, t.source_type) from ops.freshness_override t))
           ) c(t, j)
     where c.j is not null
    union all
    select 'views', 6, j.jobname, format('select cron.schedule(%L, %L, %L);', j.jobname, j.schedule, j.command)
      from cron.job j where j.jobname like 'sidnl-%'
)
select part, string_agg(txt, E'\n\n' order by sec, k) as body
  from parts where txt <> '' group by part
"""

MANIFEST_SQL = """select version, name, md5(array_to_string(statements, E'\\n')) as md5
                    from supabase_migrations.schema_migrations order by version"""

WHAT = {"tables": "extensions, schemas, types, sequences, tables, constraints, indexes, row-level security, comments",
        "functions": "every function in silver, dash and ops plus the public sidnl_* endpoint (exact text of pg_get_functiondef) and function permissions",
        "views": "views in dependency order, grants, configuration rows (no data rows), pg_cron jobs"}


def render(conn):
    """Return {path: text} for every generated file, built from the live database."""
    _, data = rows(conn, EXPORT_SQL)
    bodies = dict(data)
    out = {}
    for n, part in enumerate(("tables", "functions", "views"), start=1):
        out[SCHEMA_FILES[part]] = HEADER.format(n=n, what=WHAT[part]) + "\n" + bodies[part].rstrip("\n") + "\n"
    _, mrows = rows(conn, MANIFEST_SQL)
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["version", "name", "md5"])
    w.writerows(mrows)
    out[MANIFEST] = buf.getvalue()
    conn.rollback()
    return out


def cmd_export(conn, _a):
    for path, text in render(conn).items():
        path.write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {path.relative_to(ROOT)} ({len(text):,} chars)")


def cmd_verify(conn, _a):
    bad = 0
    for path, text in render(conn).items():
        have = path.read_text(encoding="utf-8").replace("\r\n", "\n") if path.exists() else None
        if have != text:
            bad += 1
            print(f"DIFFERS from live: {path.relative_to(ROOT)}  (run `python sidnl.py export-schema`, review, commit)")
        else:
            print(f"ok: {path.relative_to(ROOT)}")
    if bad:
        raise SystemExit(1)


# --------------------------------------------------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(prog="sidnl", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("report")
    r = sub.add_parser("run"); r.add_argument("--force", action="store_true")
    f = sub.add_parser("refresh"); f.add_argument("--brand", required=True)
    sub.add_parser("test")
    sub.add_parser("export-schema")
    sub.add_parser("verify")
    a = ap.parse_args(argv)
    fn = {"report": cmd_report, "run": cmd_run, "refresh": cmd_refresh, "test": cmd_test,
          "export-schema": cmd_export, "verify": cmd_verify}[a.cmd]
    conn = connect()
    try:
        fn(conn, a)
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
