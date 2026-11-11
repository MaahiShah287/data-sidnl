"""
src/config.py — Centralised settings for the SIDNL chatbot.
All values come from environment variables. Never hardcode secrets.
"""
from __future__ import annotations
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(PROJECT_ROOT / ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- Database ---
    database_url: str = Field(default="", alias="DATABASE_URL")

    # --- LLM ---
    llm_provider: str = Field(default="openai", alias="LLM_PROVIDER")
    llm_api_key: str = Field(default="", alias="LLM_API_KEY")
    llm_api_base: str = Field(default="https://api.openai.com/v1", alias="LLM_API_BASE")
    llm_generator_model: str = Field(default="gpt-4o-mini", alias="LLM_GENERATOR_MODEL")
    llm_critic_model: str = Field(default="gpt-4o-mini", alias="LLM_CRITIC_MODEL")
    llm_router_model: str = Field(default="gpt-4o-mini", alias="LLM_ROUTER_MODEL")

    # --- Embeddings ---
    embedding_model: str = Field(
        default="intfloat/multilingual-e5-base", alias="EMBEDDING_MODEL"
    )

    # --- Chroma ---
    chroma_persist_dir: str = Field(default="./chroma_db", alias="CHROMA_PERSIST_DIR")
    chroma_collection_name: str = Field(default="sidnl_docs", alias="CHROMA_COLLECTION_NAME")

    # --- RAG ---
    retrieval_top_k: int = Field(default=8, alias="RETRIEVAL_TOP_K")
    rerank_enabled: bool = Field(default=False, alias="RERANK_ENABLED")
    rerank_top_n: int = Field(default=4, alias="RERANK_TOP_N")
    max_retries: int = Field(default=2, alias="MAX_RETRIES")

    # --- API ---
    api_host: str = Field(default="0.0.0.0", alias="API_HOST")
    api_port: int = Field(default=8000, alias="API_PORT")
    log_level: str = Field(default="INFO", alias="LOG_LEVEL")

    # --- Metric dictionary ---
    metric_dictionary_path: str = Field(
        default=str(PROJECT_ROOT / "metrics" / "metric_dictionary.yaml"),
        alias="METRIC_DICTIONARY_PATH",
    )

    # --- Documentation corpus (DEFINITION questions) ---
    docs_dir: str = Field(
        default=str(PROJECT_ROOT.parent / "data-sidnl" / "docs"),
        alias="DOCS_DIR",
    )


settings = Settings()
