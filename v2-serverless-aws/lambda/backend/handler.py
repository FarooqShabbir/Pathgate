"""
Lambda entrypoint. Wraps the exact same FastAPI app used by every
other deployment (apps/backend/app/main.py) with Mangum, which
translates API Gateway's event/response shape into ASGI calls and
back. The app itself has no idea it's running in Lambda -- it just
sees STORAGE_BACKEND=dynamodb (set on the function) and picks
DynamoStorage via the same get_storage() factory v1/ECS/Beanstalk use.
"""
from mangum import Mangum

from app.main import app

handler = Mangum(app)
