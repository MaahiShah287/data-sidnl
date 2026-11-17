"""Turns a downloaded report (csv / xlsx / zip of those) into row dicts. Values are kept as text:
typing happens later in silver, once the real column set of each report is known."""
from __future__ import annotations

import hashlib
import json
import zipfile
from pathlib import Path
from typing import Iterator

import pandas as pd


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _frames(path: Path) -> Iterator[tuple[str, pd.DataFrame]]:
    """Yields (origin, frame). `origin` is only the part INSIDE the download (zip member / sheet name),
    never the outer file name: that name contains the request id and dates, which would make identical
    data hash differently on every run."""
    suffix = path.suffix.lower()
    if suffix == ".zip":
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if name.endswith("/"):
                    continue
                with z.open(name) as fh:
                    yield from _read_stream(Path(name).suffix.lower(), fh, name)
        return
    with open(path, "rb") as fh:
        yield from _read_stream(suffix, fh, "")


def _read_stream(suffix: str, fh, origin: str) -> Iterator[tuple[str, pd.DataFrame]]:
    if suffix in (".csv", ".txt", ""):
        yield origin, pd.read_csv(fh, dtype=str, keep_default_na=False, encoding_errors="replace")
    elif suffix in (".xlsx", ".xlsm", ".xls"):
        sheets = pd.read_excel(fh, sheet_name=None, dtype=str, keep_default_na=False)
        multi = len(sheets) > 1
        for sheet, df in sheets.items():
            yield (f"{origin}#{sheet}" if origin else (str(sheet) if multi else "")), df
    else:
        raise ValueError(f"unsupported report file type: {origin or suffix}")


def read_rows(path: Path) -> list[dict]:
    """Every row of every sheet/file as text. `_source` (zip member / sheet) is added only when the
    download has several parts, so the same data always produces the same row content."""
    rows: list[dict] = []
    for source, df in _frames(path):
        df.columns = [str(c).strip() for c in df.columns]
        for rec in df.to_dict(orient="records"):
            rec = {k: ("" if v is None else str(v).strip()) for k, v in rec.items()}
            if source:
                rec["_source"] = source
            rows.append(rec)
    return rows


def row_hash(row: dict) -> str:
    """Content identity: same content -> same hash, independent of column order."""
    canon = json.dumps(row, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


def row_identity(row: dict, key_columns: list[str]) -> tuple[str, str]:
    """(row_key, row_hash). With configured key columns the key is those values, so a changed row is
    recognised as a new VERSION of the same row. Without key columns the key is the content hash,
    so a changed row shows up as a new row (still nothing is overwritten or deleted)."""
    h = row_hash(row)
    if not key_columns:
        return h, h
    missing = [c for c in key_columns if c not in row]
    if missing:
        raise KeyError(f"key column(s) {missing} not in file (columns: {sorted(row)})")
    return "|".join(row[c] for c in key_columns), h
