"""Process-local infrastructure inventory API."""

from contextlib import asynccontextmanager
from datetime import datetime, timezone
import json
import logging
from pathlib import Path
import sys
from threading import Lock
from time import perf_counter
from typing import Literal
from urllib.parse import quote

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="INVENTORY_")

    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    unready_file: Path = Path("/tmp/inventory-api.unready")


class Asset(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)

    id: str = Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
    name: str = Field(min_length=1, max_length=256)
    environment: Literal["dev", "qa", "prod"]
    type: str = Field(min_length=1, max_length=128)
    status: str = Field(min_length=1, max_length=128)


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return json.dumps({
            "timestamp": datetime.fromtimestamp(record.created, timezone.utc).isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            **getattr(record, "request_info", {}),
        })


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    logger = logging.getLogger("inventory.requests")
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(JsonFormatter())
        logger.addHandler(handler)
    logger.setLevel(settings.log_level)
    logger.propagate = False
    assets: dict[str, Asset] = {}
    lock = Lock()

    @asynccontextmanager
    async def lifespan(application: FastAPI):
        application.state.initialized = True
        try:
            yield
        finally:
            application.state.initialized = False
            with lock:
                assets.clear()

    application = FastAPI(title="Infrastructure Inventory API", version="1.0.0", lifespan=lifespan)
    application.state.initialized = False

    @application.middleware("http")
    async def log_request(request: Request, call_next):
        started = perf_counter()
        status_code = 500
        try:
            response = await call_next(request)
            status_code = response.status_code
            return response
        finally:
            logger.info("request_completed", extra={"request_info": {
                "method": request.method,
                "path": request.url.path,
                "status_code": status_code,
                "duration_ms": round((perf_counter() - started) * 1000, 3),
                "client": request.client.host if request.client else None,
            }})

    @application.get("/health")
    def health():
        return {"status": "alive"}

    @application.get("/ready", responses={503: {"description": "Application is not ready"}})
    def ready():
        try:
            dependency_failed = settings.unready_file.exists()
        except OSError:
            dependency_failed = True
        if not application.state.initialized or dependency_failed:
            return JSONResponse(status_code=503, content={"status": "unready"})
        return {"status": "ready"}

    @application.get("/items", response_model=list[Asset])
    def list_items():
        with lock:
            return list(assets.values())

    @application.get("/items/{id}", response_model=Asset, responses={404: {"description": "Asset not found"}})
    def get_item(id: str):
        with lock:
            if id not in assets:
                raise HTTPException(status_code=404, detail="Asset not found")
            return assets[id]

    @application.post("/items", response_model=Asset, status_code=201,
                      responses={409: {"description": "Asset ID already exists"}})
    def create_item(asset: Asset, response: Response):
        with lock:
            if asset.id in assets:
                raise HTTPException(status_code=409, detail="Asset ID already exists")
            assets[asset.id] = asset
        response.headers["Location"] = f"/items/{quote(asset.id, safe='')}"
        return asset

    @application.delete("/items/{id}", status_code=204,
                        responses={404: {"description": "Asset not found"}})
    def delete_item(id: str):
        with lock:
            if id not in assets:
                raise HTTPException(status_code=404, detail="Asset not found")
            del assets[id]
        return Response(status_code=204)

    return application


app = create_app()
