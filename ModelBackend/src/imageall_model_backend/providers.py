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
