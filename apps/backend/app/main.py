from typing import List

from fastapi import APIRouter, FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .schemas import ItemCreate, ItemOut
from .storage import get_storage

app = FastAPI(title="Pathgate Backend API", version="1.0.0")

# The browser always talks to this API through the same reverse proxy
# (nginx in v1, ALB in ECS/Beanstalk, API Gateway in Lambda) that
# served the frontend, so this is same-origin in every deployment.
# CORS is left open only to make the API directly testable with curl.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Routes are mounted under /api on purpose, and every proxy in front of
# this service (nginx, the ALB, API Gateway) forwards the /api/* path
# through UNCHANGED rather than stripping it -- see each deployment's
# README for why. Frontend fetch calls already target `/api/...`.
router = APIRouter(prefix="/api")


@router.get("/health")
def health():
    storage = get_storage()
    storage.health()
    return {"status": "ok"}


@router.post("/items", response_model=ItemOut, status_code=201)
def create_item(item: ItemCreate):
    """Used exclusively by frontend-insert (app1)."""
    storage = get_storage()
    return storage.create_item(item.title, item.description)


@router.get("/items", response_model=List[ItemOut])
def list_items():
    """Used exclusively by frontend-list (app2)."""
    storage = get_storage()
    return storage.list_items()


app.include_router(router)
