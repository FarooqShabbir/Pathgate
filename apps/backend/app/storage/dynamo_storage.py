import os
import uuid
from datetime import datetime, timezone
from typing import List

import boto3

from ..schemas import ItemOut
from .base import ItemStorage


class DynamoStorage(ItemStorage):
    """Used by the AWS Lambda variant (v2/lambda). DynamoDB is chosen
    there instead of RDS Postgres so the backend stays a plain,
    stateless Lambda function with no VPC/NAT/connection-pool concerns.
    """

    def __init__(self) -> None:
        table_name = os.getenv("DYNAMODB_TABLE", "pathgate-items")
        resource_kwargs = {}
        endpoint = os.getenv("DYNAMODB_ENDPOINT_URL")  # for local testing via dynamodb-local
        if endpoint:
            resource_kwargs["endpoint_url"] = endpoint
        self.table = boto3.resource("dynamodb", **resource_kwargs).Table(table_name)

    def create_item(self, title: str, description: str | None) -> ItemOut:
        item_id = str(uuid.uuid4())
        created_at = datetime.now(timezone.utc)
        self.table.put_item(
            Item={
                "id": item_id,
                "title": title,
                "description": description or "",
                "created_at": created_at.isoformat(),
            }
        )
        return ItemOut(id=item_id, title=title, description=description, created_at=created_at)

    def list_items(self) -> List[ItemOut]:
        # A demo-scale Scan is fine here; a production table would add a
        # GSI keyed on a constant partition + created_at sort key so this
        # becomes a Query instead.
        items = self.table.scan().get("Items", [])
        items.sort(key=lambda i: i["created_at"], reverse=True)
        return [
            ItemOut(
                id=i["id"],
                title=i["title"],
                description=i.get("description") or None,
                created_at=i["created_at"],
            )
            for i in items
        ]

    def health(self) -> bool:
        self.table.meta.client.describe_table(TableName=self.table.table_name)
        return True
