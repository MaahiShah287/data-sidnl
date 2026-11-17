from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
BASE_URL = "https://brands.zepto.co.in"


def load_dotenv(path: Path | None = None) -> None:
    """Tiny .env reader (KEY=VALUE lines). Existing environment variables win."""
    path = path or ROOT / ".env"
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


@dataclass
class Account:
    """One onboarded company (a brand's Zepto portal login)."""
    name: str
    brand: str
    email: str
    otp_route: str = "manual"

    @property
    def state_file(self) -> Path:
        return ROOT / "state" / f"{self.name}.json"

    @property
    def password(self) -> str | None:
        from . import vault  # imported lazily: only needed for unattended re-login
        try:
            return vault.get_password(self.name)
        except RuntimeError:
            return None


@dataclass
class Report:
    key: str
    label: str
    enabled: bool = True
    lookback_days: int = 7
    max_days: int = 31
    key_columns: list[str] | None = None

    def __post_init__(self):
        self.key_columns = self.key_columns or []


@dataclass
class Settings:
    reports: list[Report]
    request_timeout_min: int
    poll_seconds: int
    raw_dir: Path
    headless: bool
    db_url: str | None
    otp_provider: str
    alert_webhook: str | None


def load_settings(path: Path | None = None) -> Settings:
    load_dotenv()
    cfg = yaml.safe_load((path or ROOT / "config" / "reports.yaml").read_text(encoding="utf-8"))
    d = cfg.get("defaults", {})
    reports = [
        Report(
            key=r["key"],
            label=r["label"],
            enabled=r.get("enabled", True),
            lookback_days=r.get("lookback_days", d.get("lookback_days", 7)),
            max_days=r.get("max_days", d.get("max_days", 31)),
            key_columns=r.get("key_columns", []) or [],
        )
        for r in cfg["reports"]
    ]
    return Settings(
        reports=reports,
        request_timeout_min=d.get("request_timeout_min", 25),
        poll_seconds=d.get("poll_seconds", 20),
        raw_dir=ROOT / os.environ.get("RAW_DIR", "data/raw"),
        headless=os.environ.get("HEADLESS", "1") != "0",
        db_url=os.environ.get("SUPABASE_DB_URL"),
        otp_provider=os.environ.get("OTP_PROVIDER", "manual"),
        alert_webhook=os.environ.get("ALERT_WEBHOOK_URL"),
    )
