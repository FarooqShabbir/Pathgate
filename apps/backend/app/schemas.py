from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class ItemCreate(BaseModel):
    title: str = Field(..., min_length=1, max_length=200)
    description: Optional[str] = Field(None, max_length=1000)


class ItemOut(BaseModel):
    id: str
    title: str
    description: Optional[str] = None
    created_at: datetime
