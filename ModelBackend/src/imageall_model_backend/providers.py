from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class EmbeddingProviderIdentity:
    provider: str
    model_id: str
    model_revision: str
    preprocessing_revision: str
    element_count: int


class EmbeddingProvider(Protocol):
    identity: EmbeddingProviderIdentity

    def embed(self, image_bytes: bytes) -> list[float]: ...


@dataclass(frozen=True)
class StandardProviderIdentity:
    provider: str
    model_id: str
    model_revision: str
    preprocessing_revision: str


@dataclass(frozen=True)
class StandardProviderScore:
    provider_label: str
    score: float


class StandardSuggestionProvider(Protocol):
    identity: StandardProviderIdentity

    def predict(self, image_bytes: bytes) -> list[StandardProviderScore]: ...
