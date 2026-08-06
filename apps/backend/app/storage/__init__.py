"""
Storage abstraction so the same FastAPI app can run against either a
relational database (v1 docker-compose, ECS Fargate, Elastic Beanstalk)
or DynamoDB (the AWS Lambda / serverless variant), selected purely by
the STORAGE_BACKEND environment variable. Route handlers in main.py
never import a driver directly -- they only call get_storage().
"""
import os
from functools import lru_cache

from .base import ItemStorage


@lru_cache
def get_storage() -> ItemStorage:
    backend = os.getenv("STORAGE_BACKEND", "postgres").lower()

    if backend == "postgres":
        from .postgres_storage import PostgresStorage
        return PostgresStorage()

    if backend == "dynamodb":
        from .dynamo_storage import DynamoStorage
        return DynamoStorage()

    raise ValueError(f"Unknown STORAGE_BACKEND: {backend!r}")
