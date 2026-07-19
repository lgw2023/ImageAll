from __future__ import annotations

import hashlib
import sqlite3
from pathlib import Path

import numpy as np

from imageall_model_backend.providers import EmbeddingProviderIdentity


class EmbeddingCache:
    def __init__(self, path: Path) -> None:
        self._path = path
        self._available = False
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with sqlite3.connect(path) as connection:
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS embedding_cache (
                        catalog_scope_id TEXT NOT NULL,
                        asset_id TEXT NOT NULL,
                        content_revision TEXT NOT NULL,
                        provider TEXT NOT NULL,
                        model_id TEXT NOT NULL,
                        model_revision TEXT NOT NULL,
                        preprocessing_revision TEXT NOT NULL,
                        element_count INTEGER NOT NULL,
                        embedding BLOB NOT NULL,
                        embedding_sha256 TEXT NOT NULL,
                        PRIMARY KEY (
                            catalog_scope_id,
                            asset_id,
                            content_revision,
                            provider,
                            model_id,
                            model_revision,
                            preprocessing_revision,
                            element_count
                        )
                    )
                    """
                )
        except (OSError, sqlite3.Error):
            return
        self._available = True

    def get(
        self,
        *,
        catalog_scope_id: str,
        asset_id: str,
        content_revision: str,
        encoder: EmbeddingProviderIdentity,
    ) -> list[float] | None:
        if not self._available:
            return None
        try:
            with sqlite3.connect(self._path) as connection:
                row = connection.execute(
                    """
                    SELECT embedding, embedding_sha256
                    FROM embedding_cache
                    WHERE catalog_scope_id = ?
                      AND asset_id = ?
                      AND content_revision = ?
                      AND provider = ?
                      AND model_id = ?
                      AND model_revision = ?
                      AND preprocessing_revision = ?
                      AND element_count = ?
                    """,
                    self._key_values(
                        catalog_scope_id,
                        asset_id,
                        content_revision,
                        encoder,
                    ),
                ).fetchone()
        except (OSError, sqlite3.Error):
            self._available = False
            return None
        if row is None:
            return None
        embedding_bytes = row[0]
        if (
            not isinstance(embedding_bytes, bytes)
            or len(embedding_bytes) != encoder.element_count * 4
            or not isinstance(row[1], str)
            or hashlib.sha256(embedding_bytes).hexdigest() != row[1]
        ):
            return None
        vector = np.frombuffer(embedding_bytes, dtype="<f4")
        if vector.size != encoder.element_count or not np.isfinite(vector).all():
            return None
        return [float(value) for value in vector]

    def put(
        self,
        *,
        catalog_scope_id: str,
        asset_id: str,
        content_revision: str,
        encoder: EmbeddingProviderIdentity,
        embedding: list[float],
    ) -> None:
        if not self._available:
            return
        vector = np.asarray(embedding, dtype="<f4")
        embedding_bytes = vector.tobytes()
        try:
            with sqlite3.connect(self._path) as connection:
                connection.execute(
                    """
                    INSERT OR REPLACE INTO embedding_cache (
                        catalog_scope_id,
                        asset_id,
                        content_revision,
                        provider,
                        model_id,
                        model_revision,
                        preprocessing_revision,
                        element_count,
                        embedding,
                        embedding_sha256
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        *self._key_values(
                            catalog_scope_id,
                            asset_id,
                            content_revision,
                            encoder,
                        ),
                        embedding_bytes,
                        hashlib.sha256(embedding_bytes).hexdigest(),
                    ),
                )
        except (OSError, sqlite3.Error):
            self._available = False

    @staticmethod
    def _key_values(
        catalog_scope_id: str,
        asset_id: str,
        content_revision: str,
        encoder: EmbeddingProviderIdentity,
    ) -> tuple[str, str, str, str, str, str, str, int]:
        return (
            catalog_scope_id,
            asset_id,
            content_revision,
            encoder.provider,
            encoder.model_id,
            encoder.model_revision,
            encoder.preprocessing_revision,
            encoder.element_count,
        )
