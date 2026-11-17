"""Encrypted store for portal passwords (one entry per onboarded company).

Passwords are never written to the database, the YAML, logs or the repo. They live in an encrypted file
(`data/secrets.enc`, Fernet/AES) that can only be read with VAULT_KEY (an environment variable / your
secret manager). For production, a managed secret store (Supabase Vault, AWS/GCP Secret Manager) is the
better home; this module is the small interface to swap.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from cryptography.fernet import Fernet, InvalidToken

from .config import ROOT

VAULT_FILE = ROOT / "data" / "secrets.enc"


def generate_key() -> str:
    return Fernet.generate_key().decode()


def _fernet() -> Fernet:
    key = os.environ.get("VAULT_KEY")
    if not key:
        raise RuntimeError("VAULT_KEY is not set. Generate one with: python -m zepto_fp.run vault-key")
    return Fernet(key.encode())


def _read() -> dict[str, str]:
    if not VAULT_FILE.exists():
        return {}
    try:
        return json.loads(_fernet().decrypt(VAULT_FILE.read_bytes()))
    except InvalidToken as e:
        raise RuntimeError("VAULT_KEY does not match data/secrets.enc") from e


def _write(data: dict[str, str]) -> None:
    VAULT_FILE.parent.mkdir(parents=True, exist_ok=True)
    VAULT_FILE.write_bytes(_fernet().encrypt(json.dumps(data).encode()))
    try:
        VAULT_FILE.chmod(0o600)
    except OSError:
        pass


def set_password(name: str, password: str) -> None:
    data = _read()
    data[name] = password
    _write(data)


def get_password(name: str) -> str | None:
    return _read().get(name)
