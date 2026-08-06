import os
import uuid
from typing import List

from sqlalchemy import Column, DateTime, String, create_engine, text
from sqlalchemy.orm import declarative_base, sessionmaker
from sqlalchemy.sql import func

from ..schemas import ItemOut
from .base import ItemStorage

Base = declarative_base()


class ItemRow(Base):
    __tablename__ = "items"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    title = Column(String(200), nullable=False)
    description = Column(String(1000), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())


def _database_url() -> str:
    user = os.getenv("POSTGRES_USER", "pathgate")
    password = os.getenv("POSTGRES_PASSWORD", "pathgate")
    db = os.getenv("POSTGRES_DB", "pathgate")
    host = os.getenv("DB_HOST", "db")
    port = os.getenv("DB_PORT", "5432")
    return f"postgresql://{user}:{password}@{host}:{port}/{db}"


class PostgresStorage(ItemStorage):
    """Used by v1 (docker-compose), the ECS Fargate variant, and the
    Elastic Beanstalk variant -- anywhere the DB is an RDS/self-hosted
    Postgres instance reachable over TCP:5432."""

    def __init__(self) -> None:
        self.engine = create_engine(_database_url(), pool_pre_ping=True)
        self.SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=self.engine)
        Base.metadata.create_all(bind=self.engine)

    def create_item(self, title: str, description: str | None) -> ItemOut:
        with self.SessionLocal() as db:
            row = ItemRow(id=str(uuid.uuid4()), title=title, description=description)
            db.add(row)
            db.commit()
            db.refresh(row)
            return ItemOut(id=row.id, title=row.title, description=row.description, created_at=row.created_at)

    def list_items(self) -> List[ItemOut]:
        with self.SessionLocal() as db:
            rows = db.query(ItemRow).order_by(ItemRow.created_at.desc()).all()
            return [ItemOut(id=r.id, title=r.title, description=r.description, created_at=r.created_at) for r in rows]

    def health(self) -> bool:
        with self.SessionLocal() as db:
            db.execute(text("SELECT 1"))
            return True
