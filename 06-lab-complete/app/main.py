"""
Production AI Agent — Part 6 Final Project

  GET  /health  liveness  — luôn 200 khi process còn chạy (kể cả Redis chết)
  GET  /ready   readiness — 200 khi Redis OK, 503 khi Redis mất kết nối / đang tắt
  POST /ask     X-API-Key → rate limit (Redis) → cost guard (Redis) → mock LLM

Kiểm tra:  python check_production_ready.py
"""
import asyncio
import json
import logging
import sys
import threading
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.auth import verify_api_key
from app.config import settings
from app.cost_guard import check_budget, estimate_tokens, record_cost
from app.rate_limiter import check_rate_limit
from app.redis_client import redis_healthy
from utils.mock_llm import ask as llm_ask


# ─────────────────────────────────────────────────────────
# Structured logging (tiêu chí 10): mỗi dòng log = 1 JSON object
# ─────────────────────────────────────────────────────────
class JsonFormatter(logging.Formatter):
    RESERVED = set(vars(logging.makeLogRecord({})).keys()) | {"message", "asctime"}

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.fromtimestamp(record.created, timezone.utc).isoformat(timespec="milliseconds"),
            "lvl": record.levelname,
            "logger": record.name,
            "event": record.getMessage(),
        }
        for k, v in record.__dict__.items():
            if k not in self.RESERVED and not k.startswith("_"):
                payload[k] = v
        if record.exc_info:
            payload["exc_type"] = record.exc_info[0].__name__ if record.exc_info[0] else None
        return json.dumps(payload, ensure_ascii=False, default=str)


def _setup_logging() -> logging.Logger:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    log = logging.getLogger("agent")
    log.handlers = [handler]
    log.setLevel(settings.log_level)
    log.propagate = False
    return log


logger = _setup_logging()


# ─────────────────────────────────────────────────────────
# Graceful shutdown (tiêu chí 11)
#   uvicorn bắt SIGTERM: ngừng nhận kết nối mới, chờ request đang chạy xong,
#   rồi chạy phần "shutdown" của lifespan → exit code 0.
#   Ở đây: đánh dấu đang tắt (/ready → 503 để LB ngừng route) và chờ in-flight về 0.
# ─────────────────────────────────────────────────────────
_state = {"shutting_down": False, "in_flight": 0, "started_at": time.time()}
_lock = threading.Lock()


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("startup", extra={"environment": settings.environment, "port": settings.port,
                                  "redis_ok": redis_healthy()})
    yield
    _state["shutting_down"] = True
    logger.info("shutdown_begin", extra={"in_flight": _state["in_flight"]})
    deadline = time.time() + 8          # < 10s để `docker stop` không phải SIGKILL
    while _state["in_flight"] > 0 and time.time() < deadline:
        await asyncio.sleep(0.1)
    logger.info("shutdown_complete", extra={"in_flight": _state["in_flight"]})


app = FastAPI(title="Production AI Agent", lifespan=lifespan,
              docs_url=None if settings.environment == "production" else "/docs")


@app.middleware("http")
async def access_log(request: Request, call_next):
    request_id = request.headers.get("X-Request-ID") or uuid.uuid4().hex[:12]
    start = time.perf_counter()
    with _lock:
        _state["in_flight"] += 1
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        response.headers["X-Request-ID"] = request_id
        return response
    finally:
        with _lock:
            _state["in_flight"] -= 1
        logger.info("request", extra={"request_id": request_id, "method": request.method,
                                      "path": request.url.path, "status": status,
                                      "ms": round((time.perf_counter() - start) * 1000, 1)})


# ─────────────────────────────────────────────────────────
# Xử lý lỗi: mã lỗi rõ ràng, không lộ stack trace
# ─────────────────────────────────────────────────────────
@app.exception_handler(StarletteHTTPException)
async def http_error(request: Request, exc: StarletteHTTPException):
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code,
                        headers=getattr(exc, "headers", None))


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    errors = [{"field": ".".join(str(p) for p in e["loc"][1:]), "msg": e["msg"]} for e in exc.errors()]
    return JSONResponse({"error": "Invalid request body", "details": errors}, status_code=422)


@app.exception_handler(Exception)
async def unhandled_error(request: Request, exc: Exception):
    logger.error("unhandled_error", exc_info=exc, extra={"path": request.url.path})
    return JSONResponse({"error": "Internal server error"}, status_code=500)


# ─────────────────────────────────────────────────────────
# Endpoints
# ─────────────────────────────────────────────────────────
class AskRequest(BaseModel):
    question: str = Field(..., min_length=1, max_length=2000)
    user_id: str | None = Field(default=None, max_length=100)


@app.get("/")
def root():
    return {"service": "production-ai-agent", "endpoints": ["/health", "/ready", "POST /ask"]}


@app.get("/health")
def health():
    """Liveness: không phụ thuộc Redis — chỉ cần process còn sống."""
    return {"status": "ok", "uptime_s": round(time.time() - _state["started_at"], 1),
            "environment": settings.environment}


@app.get("/ready")
def ready():
    """Readiness: Redis phải kết nối được và instance không đang tắt."""
    if _state["shutting_down"]:
        return JSONResponse({"status": "shutting_down"}, status_code=503)
    if not redis_healthy():
        return JSONResponse({"status": "not_ready", "redis": "unreachable"}, status_code=503)
    return {"status": "ready", "redis": "ok"}


@app.post("/ask")
def ask(body: AskRequest, api_key: str = Depends(verify_api_key)):
    check_rate_limit(api_key)        # 429 khi vượt RATE_LIMIT_PER_MINUTE
    check_budget()                   # 402 khi hết budget

    answer = llm_ask(body.question)

    input_tokens = estimate_tokens(body.question)
    output_tokens = estimate_tokens(answer)
    cost = record_cost(input_tokens, output_tokens)
    logger.info("llm_call", extra={"user_id": body.user_id, "input_tokens": input_tokens,
                                   "output_tokens": output_tokens, "cost_usd": round(cost, 8)})
    return {
        "question": body.question,
        "answer": answer,
        "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens,
                  "cost_usd": round(cost, 8)},
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app.main:app", host="0.0.0.0", port=settings.port)