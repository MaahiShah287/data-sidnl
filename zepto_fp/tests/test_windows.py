from datetime import date

import pytest

from zepto_fp.windows import daily_window, date_windows


def test_windows_cover_range_without_gaps_or_overlap():
    ws = date_windows(date(2026, 1, 1), date(2026, 11, 16), 31)
    assert ws[0][0] == date(2026, 1, 1) and ws[-1][1] == date(2026, 11, 16)
    for (_, prev_end), (nxt_start, _) in zip(ws, ws[1:]):
        assert (nxt_start - prev_end).days == 1
    assert all((e - s).days + 1 <= 31 for s, e in ws)


def test_single_day_and_exact_fit():
    assert date_windows(date(2026, 5, 5), date(2026, 5, 5), 31) == [(date(2026, 5, 5), date(2026, 5, 5))]
    assert len(date_windows(date(2026, 1, 1), date(2026, 1, 31), 31)) == 1
    assert len(date_windows(date(2026, 1, 1), date(2026, 2, 1), 31)) == 2


def test_invalid_inputs():
    with pytest.raises(ValueError):
        date_windows(date(2026, 2, 1), date(2026, 1, 1), 31)
    with pytest.raises(ValueError):
        date_windows(date(2026, 1, 1), date(2026, 1, 2), 0)


def test_daily_window_ends_yesterday():
    assert daily_window(date(2026, 11, 17), 7) == (date(2026, 11, 10), date(2026, 11, 16))
    assert daily_window(date(2026, 11, 17), 1) == (date(2026, 11, 16), date(2026, 11, 16))
