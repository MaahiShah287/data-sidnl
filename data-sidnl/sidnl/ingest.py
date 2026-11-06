"""Static path: files dropped in landing/<platform>/ (parquet / csv / tsv / jsonl, optionally .gz).
Reads in chunks (bounded memory) and hands every chunk to loader.load_df - the same code the real-time path uses."""
import pathlib, shutil
from concurrent.futures import ProcessPoolExecutor
import pandas as pd
from .common import ROOT, connect, load_yaml
from . import loader

SUPPORTED = (".parquet", ".csv", ".tsv", ".txt", ".jsonl", ".ndjson", ".csv.gz", ".tsv.gz")


def chunks(path, rows):
    p, n = pathlib.Path(path), pathlib.Path(path).name.lower()
    if n.endswith(".parquet"):
        import pyarrow.parquet as pq
        for b in pq.ParquetFile(p).iter_batches(batch_size=rows):
            yield b.to_pandas()
    elif n.endswith((".csv", ".txt", ".csv.gz", ".tsv", ".tsv.gz")):
        yield from pd.read_csv(p, chunksize=rows, dtype=str, sep="\t" if ".tsv" in n else ",",
                               keep_default_na=False, na_values=[""])
    elif n.endswith((".jsonl", ".ndjson")):
        yield from pd.read_json(p, lines=True, chunksize=rows, dtype=False)
    else:
        raise ValueError(f"unsupported file type: {p.name}")


def ingest(platform, path, kind="static"):
    cfg = loader.platform_cfg()
    rows = load_yaml("matching.yaml").get("chunk_rows", 50000)
    conn = connect()
    bid, total = loader.start_batch(conn, platform, kind, path), 0
    try:
        for df in chunks(path, rows):
            total += loader.load_df(conn, platform, df, cfg)
            print(f"{platform}: {total:,} rows")
        loader.finish_batch(conn, bid, total)
    finally:
        conn.close()
    return total


def _job(args):
    return ingest(*args)


def ingest_dir(workers=None, kind="live"):
    """Load every new file in landing/<platform>/ in parallel; move to _done/ (or _failed/ with the error)."""
    import os
    workers = workers or int(os.environ.get("SIDNL_WORKERS", min(os.cpu_count() or 1, 4)))
    jobs = []
    for plat in loader.platform_cfg()["platforms"]:
        d = ROOT / "landing" / plat
        if d.exists():
            jobs += [(plat, f) for f in sorted(d.iterdir()) if f.is_file() and f.name.lower().endswith(SUPPORTED)]
    if not jobs:
        return 0
    total = 0
    with ProcessPoolExecutor(workers) as ex:
        futs = [(ex.submit(_job, (p, f, kind)), p, f) for p, f in jobs]
        for fut, plat, f in futs:
            try:
                total += fut.result()
                dest = f.parent / "_done"
            except Exception as e:
                dest = f.parent / "_failed"
                dest.mkdir(exist_ok=True)
                (dest / (f.name + ".err")).write_text(repr(e))
                print(f"FAILED {f.name}: {e}")
            dest.mkdir(exist_ok=True)
            shutil.move(str(f), str(dest / f.name))
    return total
