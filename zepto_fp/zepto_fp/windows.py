from __future__ import annotations

from datetime import date, timedelta


def date_windows(start: date, end: date, max_days: int) -> list[tuple[date, date]]:
    """Split [start, end] (inclusive) into consecutive windows of at most `max_days` days.

    The portal caps each report request at roughly a month, so a backfill is a chain of windows.
    """
    if max_days < 1:
        raise ValueError("max_days must be >= 1")
    if end < start:
        raise ValueError("end before start")
    out: list[tuple[date, date]] = []
    cur = start
    while cur <= end:
        stop = min(cur + timedelta(days=max_days - 1), end)
        out.append((cur, stop))
        cur = stop + timedelta(days=1)
    return out


def daily_window(today: date, lookback_days: int) -> tuple[date, date]:
    """Rolling window ending yesterday (today's data is incomplete)."""
    end = today - timedelta(days=1)
    return end - timedelta(days=lookback_days - 1), end
