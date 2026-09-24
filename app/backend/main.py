"""ClearShift — FastAPI entry point."""

from __future__ import annotations

import logging
import os
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from backend import config, db
from backend.routes import ask, gate, overview

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="ClearShift",
    description="Qualification gating and pre-shift safety alerts for ClearShift, on Lakebase",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(overview.router)
app.include_router(ask.router)
app.include_router(gate.router)


@app.get("/api/health", tags=["health"])
def health():
    try:
        db.query("SELECT 1 AS ok")
        return {"status": "ok", "database": config.LAKEBASE_DATABASE}
    except Exception as exc:  # noqa: BLE001
        logger.exception("health check failed")
        return {"status": "degraded", "detail": str(exc)}


# ---------------------------------------------------------------------------
# Static frontend
# ---------------------------------------------------------------------------
_FRONTEND = Path(__file__).resolve().parent.parent / "frontend"

if _FRONTEND.is_dir():
    app.mount("/static", StaticFiles(directory=str(_FRONTEND)), name="static")

    @app.get("/", include_in_schema=False)
    def index():
        return FileResponse(str(_FRONTEND / "index.html"))

    @app.get("/favicon.ico", include_in_schema=False)
    def favicon():
        return FileResponse(str(_FRONTEND / "favicon.svg"), media_type="image/svg+xml")
