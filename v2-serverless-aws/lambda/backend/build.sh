#!/usr/bin/env bash
# Produces function.zip: the shared FastAPI app code (from apps/backend)
# plus handler.py plus just enough dependencies to run it under
# Lambda. boto3 is omitted on purpose -- it ships with the Lambda
# Python runtime already. sqlalchemy/psycopg2 are omitted too: this
# variant only ever imports DynamoStorage (STORAGE_BACKEND=dynamodb),
# and app/storage/__init__.py imports drivers lazily, so the Postgres
# driver's dependencies are never touched at runtime.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BUILD="$HERE/build"

rm -rf "$BUILD" "$HERE/function.zip"
mkdir -p "$BUILD"

pip install -r "$HERE/requirements.txt" -t "$BUILD" \
  --platform manylinux2014_x86_64 --python-version 3.12 --only-binary=:all:

cp -r "$ROOT/apps/backend/app" "$BUILD/app"
cp "$HERE/handler.py" "$BUILD/handler.py"

(cd "$BUILD" && zip -r "$HERE/function.zip" . -x '*.pyc' >/dev/null)
echo "Built $HERE/function.zip"
