from __future__ import annotations

import json
import os
import shutil
import tempfile
import threading
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID, uuid4

from imageall_model_backend.personal_suggestions import PersonalSuggestionEngine
from imageall_model_backend.personal_training import (
    PersonalTrainingInput,
    load_personal_linear_head,
    train_personal_linear_head,
    validate_personal_training_input,
)
from imageall_model_backend.providers import EmbeddingProvider
from imageall_model_backend.training import LinearHeadTrainingConfig


class PersonalBundleMismatch(ValueError):
    pass


@dataclass(frozen=True)
class ExpectedActivePersonalBundle:
    bundle_revision: str
    weights_sha256: str


class PersonalModelRuntime:
    def __init__(
        self,
        *,
        provider: EmbeddingProvider,
        store_root: Path,
        training_config: LinearHeadTrainingConfig | None = None,
    ) -> None:
        self._provider = provider
        self._store_root = store_root
        self._training_config = training_config or LinearHeadTrainingConfig(
            epochs=100,
            learning_rate=0.01,
        )
        self._rebuild_lock = threading.Lock()
        self._store_root.mkdir(parents=True, exist_ok=True)
        (self._store_root / "bundles").mkdir(exist_ok=True)
        self._engine = self._load_active_engine()

    @property
    def current_engine(self) -> PersonalSuggestionEngine | None:
        return self._engine

    def rebuild(
        self,
        *,
        training_input: PersonalTrainingInput,
        expected_active_bundle: ExpectedActivePersonalBundle | None,
        should_cancel: Callable[[], bool] | None = None,
    ) -> PersonalSuggestionEngine:
        with self._rebuild_lock:
            self._validate_rebuild_identity(
                training_input=training_input,
                expected_active_bundle=expected_active_bundle,
            )
            validate_personal_training_input(training_input)
            if should_cancel is not None and should_cancel():
                raise RuntimeError("personal rebuild cancelled")
            current_engine = self._engine
            bundle_id = (
                current_engine.bundle_id
                if current_engine is not None
                else str(uuid4())
            )
            bundle_revision = str(uuid4())
            temporary_root = Path(
                tempfile.mkdtemp(prefix=".personal-rebuild-", dir=self._store_root)
            )
            candidate_path = temporary_root / "bundle"
            final_path = self._store_root / "bundles" / bundle_revision
            try:
                try:
                    train_personal_linear_head(
                        training_input=training_input,
                        output_dir=candidate_path,
                        bundle_id=bundle_id,
                        bundle_revision=bundle_revision,
                        config=self._training_config,
                    )
                    bundle = load_personal_linear_head(
                        candidate_path,
                        expected_catalog_scope_id=training_input.catalog_scope_id,
                        expected_bundle_id=bundle_id,
                        expected_bundle_revision=bundle_revision,
                        expected_encoder_identity=self._provider.identity,
                        expected_label_vocabulary_revision=(
                            training_input.label_vocabulary_revision
                        ),
                    )
                except ValueError as error:
                    raise RuntimeError(
                        "personal candidate bundle validation failed"
                    ) from error
                candidate_engine = PersonalSuggestionEngine(self._provider, bundle)
                if should_cancel is not None and should_cancel():
                    raise RuntimeError("personal rebuild cancelled")
                os.replace(candidate_path, final_path)
                if should_cancel is not None and should_cancel():
                    shutil.rmtree(final_path, ignore_errors=True)
                    raise RuntimeError("personal rebuild cancelled")
                self._write_active_pointer(candidate_engine)
                self._engine = candidate_engine
                return candidate_engine
            finally:
                shutil.rmtree(temporary_root, ignore_errors=True)

    def _validate_rebuild_identity(
        self,
        *,
        training_input: PersonalTrainingInput,
        expected_active_bundle: ExpectedActivePersonalBundle | None,
    ) -> None:
        if training_input.encoder_identity != self._provider.identity:
            raise PersonalBundleMismatch(
                "personal snapshot encoder does not match active provider"
            )
        current_engine = self._engine
        if current_engine is None:
            if expected_active_bundle is not None:
                raise PersonalBundleMismatch("personal active bundle mismatch")
            return
        identity = current_engine.bundle_identity
        if (
            training_input.catalog_scope_id != identity.catalog_scope_id
            or expected_active_bundle is None
            or expected_active_bundle.bundle_revision != identity.bundle_revision
            or expected_active_bundle.weights_sha256 != identity.weights_sha256
        ):
            raise PersonalBundleMismatch("personal active bundle mismatch")

    def _load_active_engine(self) -> PersonalSuggestionEngine | None:
        pointer_path = self._store_root / "active.json"
        if not pointer_path.exists():
            return None
        pointer = json.loads(pointer_path.read_text(encoding="utf-8"))
        if pointer["schema_revision"] != 1:
            raise ValueError("unsupported personal active pointer schema")
        bundle_revision = pointer["bundle_revision"]
        try:
            parsed_revision = UUID(bundle_revision)
        except (TypeError, ValueError):
            raise ValueError("personal bundle revision is not canonical") from None
        if str(parsed_revision) != bundle_revision:
            raise ValueError("personal bundle revision is not canonical")
        bundle_path = self._store_root / "bundles" / bundle_revision
        bundle = load_personal_linear_head(
            bundle_path,
            expected_catalog_scope_id=pointer["catalog_scope_id"],
            expected_bundle_id=pointer["bundle_id"],
            expected_bundle_revision=bundle_revision,
            expected_encoder_identity=self._provider.identity,
            expected_label_vocabulary_revision=pointer[
                "label_vocabulary_revision"
            ],
        )
        if bundle.weights_sha256 != pointer["weights_sha256"]:
            raise ValueError("personal active pointer weights mismatch")
        return PersonalSuggestionEngine(self._provider, bundle)

    def _write_active_pointer(self, engine: PersonalSuggestionEngine) -> None:
        identity = engine.bundle_identity
        pointer = {
            "schema_revision": 1,
            "catalog_scope_id": identity.catalog_scope_id,
            "bundle_id": identity.bundle_id,
            "bundle_revision": identity.bundle_revision,
            "label_vocabulary_revision": identity.label_vocabulary_revision,
            "weights_sha256": identity.weights_sha256,
        }
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=self._store_root,
            prefix=".active-",
            delete=False,
        ) as temporary_pointer:
            temporary_pointer_path = Path(temporary_pointer.name)
            json.dump(pointer, temporary_pointer, indent=2, sort_keys=True)
            temporary_pointer.write("\n")
            temporary_pointer.flush()
            os.fsync(temporary_pointer.fileno())
        try:
            os.replace(temporary_pointer_path, self._store_root / "active.json")
        finally:
            temporary_pointer_path.unlink(missing_ok=True)
