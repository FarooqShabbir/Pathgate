from abc import ABC, abstractmethod
from typing import List

from ..schemas import ItemOut


class ItemStorage(ABC):
    """Minimal persistence contract the API needs: insert + list."""

    @abstractmethod
    def create_item(self, title: str, description: str | None) -> ItemOut:
        ...

    @abstractmethod
    def list_items(self) -> List[ItemOut]:
        ...

    @abstractmethod
    def health(self) -> bool:
        ...
