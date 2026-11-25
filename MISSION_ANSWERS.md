# Day 14 Lab — Mission Answers

> **Họ tên:** Hoàng Gia Khiêm · **MSSV:** 2A202603540 · **Lớp:** K5-L3A
> Các chỗ `⟪ … ⟫` là output phải dán từ lệnh chính mình chạy (xem `HUONG_DAN_CHAY.md`).

---

## Part 1: Localhost vs Production

### Exercise 1.1: Anti-patterns trong `01-localhost-vs-production/develop/app.py`

1. **Hardcode secret** — `OPENAI_API_KEY = "sk-hardcoded-fake-key-never-do-this"` và `DATABASE_URL = "postgresql://admin:password123@..."`. Push lên GitHub là lộ key/mật khẩu, và đổi key phải sửa code + deploy lại.
2. **Log ra secret** — `print(f"[DEBUG] Using key: {OPENAI_API_KEY}")`: key nằm trong log, ai đọc log cũng thấy.
3. **Dùng `print()` thay vì logging có cấu trúc** — không có level, timestamp, không parse được bằng log aggregator (Loki, Datadog).
4. **Config cứng trong code** — `DEBUG = True`, `MAX_TOKENS = 500`: muốn đổi giữa dev/staging/prod phải sửa code.
5. **Không có `/health`** — platform không biết agent còn sống để restart khi treo.
6. **Port cố định + bind `localhost`** — `host="localhost", port=8000`: trong container/cloud không nhận được kết nối từ ngoài, và bỏ qua biến `PORT` mà Railway/Render inject.
7. **`reload=True` trong production** — tốn tài nguyên, theo dõi file thay đổi, không dùng cho prod.
8. **Không xử lý graceful shutdown** — SIGTERM là process chết ngay, request đang chạy bị cắt.

### Exercise 1.2: Chạy bản develop

```bash
cd 01-localhost-vs-production/develop && pip install -r requirements.txt && python app.py
curl -X POST "http://localhost:8000/ask?question=Hello"
```

⟪ dán output curl ⟫

Nó chạy được, nhưng chưa production-ready vì 8 vấn đề ở trên (đặc biệt là secret trong code và không có health check).

### Exercise 1.3: So sánh develop vs production

| Feature | Develop | Production | Tại sao quan trọng? |
|---|---|---|---|
| Config | Hardcode trong code (`DEBUG=True`, key, DB URL) | Đọc env var qua `config.py` (`settings`) | Cùng một image chạy ở mọi môi trường; secret không nằm trong git |
| Secret | In ra log | Không log secret, chỉ log `question_length` | Log thường được nhiều người/hệ thống đọc |
| Health check | Không có | `GET /health` (liveness) + `GET /ready` (readiness, 503 khi chưa sẵn sàng) | Platform biết khi nào restart, LB biết khi nào route traffic |
| Logging | `print()` | JSON qua `logging` (`{"time":..,"level":..,"msg":..}`) | Parse/tìm kiếm/lọc được trong log aggregator |
| Shutdown | Đột ngột | `lifespan` (startup/shutdown) + handler SIGTERM, `is_ready=False` khi tắt | Không cắt ngang request đang chạy khi deploy/scale down |
| Host/Port | `localhost:8000` cứng | `0.0.0.0` + `PORT` từ env | Chạy được trong container và trên cloud |
| Reload/Debug | `reload=True` luôn | `reload=settings.debug` | Không chạy chế độ dev ở production |
| CORS | Không có | `allowed_origins` từ config | Chỉ cho phép frontend hợp lệ gọi API |

---

## Part 2: Docker

### Exercise 2.1: `02-docker/develop/Dockerfile`

1. **Base image:** `python:3.11` — bản Python đầy đủ (Debian + build tools), khoảng 1 GB.
2. **Working directory:** `/app` (`WORKDIR /app`).
3. **Vì sao COPY `requirements.txt` trước:** Docker cache theo layer. Dependencies ít thay đổi hơn code, nên copy + `pip install` trước thì khi chỉ sửa `app.py`, layer cài thư viện vẫn dùng cache → build lại chỉ vài giây thay vì cài lại toàn bộ.
4. **CMD vs ENTRYPOINT:** `ENTRYPOINT` là lệnh chính cố định của container; `CMD` là lệnh/tham số mặc định, bị ghi đè khi chạy `docker run image <lệnh khác>`. Khi dùng cả hai, CMD trở thành tham số cho ENTRYPOINT. Ở đây dùng `CMD ["python", "app.py"]` (exec form → python là PID 1, nhận được SIGTERM).

### Exercise 2.2: Build và chạy

```bash
docker build -f 02-docker/develop/Dockerfile -t my-agent:develop .
docker run --rm -p 8000:8000 my-agent:develop
curl -X POST "http://localhost:8000/ask?question=What%20is%20Docker"
```

⟪ dán output curl ⟫

### Exercise 2.3: Multi-stage build (`02-docker/production/Dockerfile`)

- **Stage 1 (builder):** `python:3.11-slim` + cài `gcc`, `libpq-dev`, rồi `pip install --user` → packages nằm ở `/root/.local`.
- **Stage 2 (runtime):** `python:3.11-slim` sạch, tạo user non-root `appuser`, chỉ `COPY --from=builder /root/.local`, code `main.py` và `utils/`, có `HEALTHCHECK`, chạy `uvicorn ... --workers 2`.
- **Vì sao nhỏ hơn:** image cuối không chứa gcc, header, apt cache, pip cache của stage builder; và dùng base `slim` thay vì bản full.

```bash
docker build -f 02-docker/production/Dockerfile -t my-agent:advanced .
docker images | grep my-agent
```

⟪ dán output `docker images` ⟫

- Develop: **⟪ X ⟫ MB**
- Production: **⟪ Y ⟫ MB**
- Chênh lệch: **⟪ (X−Y)/X×100 ⟫ %** nhỏ hơn

### Exercise 2.4: Docker Compose stack

```
                 :80
  Client ──▶ ┌─────────┐        network "internal" (bridge)
             │  nginx  │──────────────┐
             └─────────┘              ▼
                               ┌────────────┐
                               │   agent    │ (FastAPI, uvicorn 2 workers, không expose port)
                               └──┬──────┬──┘
                    REDIS_URL     │      │  QDRANT_URL
                                  ▼      ▼
                          ┌────────┐  ┌────────┐
                          │ redis  │  │ qdrant │
                          └────────┘  └────────┘
```

- Services: `agent`, `redis`, `qdrant`, `nginx`. Agent chỉ khởi động sau khi redis và qdrant `service_healthy`.
- Giao tiếp qua DNS nội bộ của Docker (`redis:6379`, `qdrant:6333`, `agent:8000`). Chỉ nginx mở cổng ra host (80/443); nginx reverse proxy + rate limit 10 r/s theo IP rồi chuyển tới `agent_backend`.

```bash
cd 02-docker/production && touch .env.local
docker compose -p k5-day14-docker up -d --build
curl http://localhost/health
curl -X POST http://localhost/ask -H "Content-Type: application/json" -d '{"question": "Explain microservices"}'
docker compose -p k5-day14-docker down
```

⟪ dán output ⟫

---

## Part 3: Cloud Deployment

### Exercise 3.1 / 3.2: Deploy agent Part 6

- Nền tảng chính: **⟪ Railway / Render ⟫**
- URL: **⟪ https://… ⟫** (chi tiết trong `DEPLOYMENT.md`)
- Ảnh: `screenshots/dashboard.png`, `screenshots/running.png`, `screenshots/test.png`

Kết quả 4 lệnh tự kiểm (CP6):

```
⟪ 200
200
401
200 ⟫
```

### So sánh `railway.toml` và `render.yaml` (06-lab-complete)

| | `railway.toml` | `render.yaml` |
|---|---|---|
| Định dạng | TOML, chỉ cấu hình **1 service** | YAML Blueprint, khai báo **nhiều service** (agent + Redis Key Value) trong một file |
| Build | `builder = "DOCKERFILE"` | `runtime: docker`, `dockerfilePath`, `rootDir` |
| Health check | `healthcheckPath = "/health"` | `healthCheckPath: /health` |
| Restart | `restartPolicyType = "ON_FAILURE"` | Render tự restart, không cần khai báo |
| Biến môi trường | **Không** nằm trong file; đặt bằng `railway variables set` / dashboard | Khai báo trong `envVars`; secret dùng `sync: false` (nhập tay trên dashboard) hoặc `generateValue: true`; `REDIS_URL` lấy bằng `fromService` |
| Redis | Thêm plugin Redis trong project rồi tham chiếu `${{Redis.REDIS_URL}}` | Service `type: keyvalue` cùng file |
| Deploy | `railway up` từ CLI (upload thư mục) | Kết nối GitHub repo → New Blueprint, deploy lại mỗi lần push |

Lý do khác nhau: Railway theo hướng "CLI + project", cấu hình hạ tầng nằm trên dashboard; Render theo hướng Infrastructure-as-Code, cả hạ tầng (web + Redis + env) nằm trong file trong repo.

### Exercise 3.3: Pipeline Cloud Run (`cloudbuild.yaml` + `service.yaml`)

1. **test** — container `python:3.11-slim` cài requirements + pytest, chạy `pytest tests/`; fail là dừng pipeline.
2. **build** — `docker build` image, gắn 2 tag `:$COMMIT_SHA` và `:latest`, dùng `--cache-from :latest` để tận dụng layer cache.
3. **push** — đẩy mọi tag lên Container Registry `gcr.io/$PROJECT_ID/ai-agent`.
4. **deploy** — `gcloud run deploy` image theo commit SHA lên `asia-southeast1`, min 1 / max 10 instance, 512Mi/1 CPU, timeout 60s, secret lấy từ **Secret Manager** (`--set-secrets`), không ghi trong code.
5. `service.yaml` mô tả cùng service theo dạng Knative khai báo: autoscaling (min 1, max 10, target 80 concurrent), `containerConcurrency: 80`, liveness/startup probe `/health`, secret qua `secretKeyRef`.

---

## Part 4: API Security

### Exercise 4.1: API key (`04-api-gateway/develop/app.py`)

- **Check ở đâu:** dependency `verify_api_key()` đọc header `X-API-Key` qua `APIKeyHeader`, gắn vào `/ask` bằng `Depends(verify_api_key)`.
- **Sai key:** thiếu key → **401**; có key nhưng sai → **403** (bản develop). (Ở Part 6 mình trả 401 cho cả hai theo hợp đồng.)
- **Rotate key:** key đọc từ env `AGENT_API_KEY` → đặt giá trị mới trên platform và restart/redeploy, không sửa code. Muốn không downtime thì cho phép tạm thời 2 key (cũ + mới) rồi bỏ key cũ.

```bash
cd 04-api-gateway/develop && AGENT_API_KEY=secret-key-123 python app.py
curl -i -X POST http://localhost:8000/ask -H "Content-Type: application/json" -d '{"question": "Hello"}'
curl -i -X POST http://localhost:8000/ask -H "X-API-Key: secret-key-123" -H "Content-Type: application/json" -d '{"question": "Hello"}'
```

⟪ dán output: HTTP/1.1 401 … và HTTP/1.1 200 … ⟫

### Exercise 4.2: JWT (`04-api-gateway/production`)

Flow: `POST /auth/token` (username/password) → server ký JWT HS256 chứa `sub`, `role`, `iat`, `exp` (60 phút) → client gửi `Authorization: Bearer <token>` → `verify_token()` kiểm chữ ký + hạn; hết hạn → 401, token sai → 403. Server không cần tra DB mỗi request (stateless).

```bash
curl -s -X POST http://localhost:8000/auth/token -H "Content-Type: application/json" -d '{"username":"student","password":"demo123"}'
```

⟪ dán output, che token: "eyJhbGciOi…<đã che>" ⟫

### Exercise 4.3: Rate limiting

- **Algorithm:** sliding window log — mỗi user một `deque` timestamp, bỏ timestamp cũ hơn 60s rồi đếm.
- **Limit:** user thường **10 req/phút** (`rate_limiter_user`), admin **100 req/phút** (`rate_limiter_admin`).
- **Bypass cho admin:** `app.py` chọn limiter theo `role` trong JWT — role `admin` (tài khoản `teacher`) dùng limiter 100/phút.
- Hạn chế: state trong memory → mỗi instance đếm riêng và mất khi restart; Part 6 chuyển sang Redis sorted set.

```bash
for i in {1..20}; do curl -s -o /dev/null -w "$i: %{http_code}\n" -X POST http://localhost:8000/ask \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"question\": \"Test $i\"}"; done
```

⟪ dán output: 1–10 → 200, 11–20 → 429 ⟫

### Exercise 4.4: Cost guard

Cách làm trong Part 6 (`06-lab-complete/app/cost_guard.py`):

- `check_budget()` gọi **trước** LLM: đọc tổng chi phí từ Redis (`cost:daily:YYYY-MM-DD`, `cost:monthly:YYYY-MM`); ≥ `DAILY_BUDGET_USD` hoặc ≥ `MONTHLY_BUDGET_USD` → **402 Payment Required**.
- `record_cost()` gọi **sau** LLM: cost = input_tokens/1000 × $0.00015 + output_tokens/1000 × $0.0006, cộng bằng `INCRBYFLOAT` (atomic, nhiều worker/instance dùng chung), đặt `EXPIRE` 2 ngày / 32 ngày → tự "reset" khi sang ngày/tháng mới vì key đổi tên.
- Redis lỗi → 503 (fail closed), để không chi tiền khi không đếm được.
- Rate limit bảo vệ **tốc độ** (chống spam/DoS), cost guard bảo vệ **tiền** (nhiều request hợp lệ cộng lại vẫn có thể vượt ngân sách) → cần cả hai.

---

## Part 5: Scaling & Reliability

### Exercise 5.1: Health checks
`05-scaling-reliability/develop/app.py`: `/health` (liveness) trả 200 + uptime, memory (psutil) khi process còn sống; `/ready` (readiness) trả 503 khi `_is_ready=False` (đang khởi động/đang tắt). Khác biệt: liveness fail → platform **restart** container; readiness fail → LB **ngừng gửi traffic** nhưng không restart. Vì vậy `/health` không được phụ thuộc Redis (Redis chết mà restart agent cũng vô ích), còn `/ready` thì có.

⟪ dán output `curl localhost:8000/health` và `/ready` ⟫

### Exercise 5.2: Graceful shutdown
Middleware đếm `_in_flight_requests`; khi SIGTERM, uvicorn ngừng nhận kết nối mới, `lifespan` đặt `_is_ready=False` và chờ in-flight về 0 (tối đa timeout) rồi thoát. Handler SIGTERM tự viết chỉ log và **để uvicorn tự xử lý** — nếu nuốt mất handler của uvicorn thì process không bao giờ tắt.

```bash
python app.py & PID=$!; sleep 2
curl -X POST "http://localhost:8000/ask?question=Long%20task" & sleep 0.2; kill -TERM $PID; wait
```

⟪ dán output: request vẫn trả 200, log "Waiting for 1 in-flight requests…" rồi "Shutdown complete" ⟫

### Exercise 5.3: Stateless design
`production/app.py` lưu session/history ở Redis (`session:{id}` với `SETEX` TTL 1h) thay vì dict trong RAM. Lý do: khi chạy N instance sau LB, mỗi request có thể rơi vào instance khác; state trong RAM của instance A thì instance B không thấy, và mất hết khi instance restart/scale down.

### Exercise 5.4: Load balancing

```bash
cd 05-scaling-reliability/production && touch .env.local
docker compose -p k5-day14-scaling up -d --build --scale agent=3
```

Nginx (`resolver 127.0.0.11`, `upstream agent:8000`) round-robin giữa 3 container; `proxy_next_upstream error timeout http_503` → 1 instance chết thì request được thử lại sang instance khác. Header `X-Served-By` cho thấy instance phục vụ.

### Exercise 5.5: Test stateless

```bash
python test_stateless.py
docker compose -p k5-day14-scaling down
```

⟪ dán output ⟫

Giải thích: 5 câu hỏi cùng `session_id` được phục vụ bởi nhiều instance khác nhau (`Instances used` > 1), nhưng `history` vẫn đủ 10 message (5 user + 5 assistant) vì mọi instance đọc/ghi cùng Redis.

---

## Part 6: Final Project — output `check_production_ready.py`

```bash
cd 06-lab-complete && pip install -r requirements.txt && python check_production_ready.py
```

Chạy trong WSL2 (Ubuntu) + Docker Desktop 29.2.1, Python 3.11, Redis: redis-server tạm thời do script tự bật.

```text
================================================================
  📋 Checklist Deliverable
     ✅ Dockerfile (multi-stage, < 500 MB)
     ✅ docker-compose.yml (agent + redis)
     ✅ .dockerignore
     ✅ Health check endpoint (GET /health)
     ✅ Readiness endpoint (GET /ready)
     ✅ API Key authentication
     ✅ Rate limiting
     ✅ Cost guard
     ✅ Config từ environment variables
     ✅ Structured logging
     ✅ Graceful shutdown
     ✅ Public URL ready (Railway / Render config)
----------------------------------------------------------------
  Result: 12/12 tiêu chí đạt · 43/43 checks passed
  🎉 PASS 12/12 — PRODUCTION READY! Deploy nào!
================================================================
```

Tóm tắt cách làm từng tiêu chí:

| # | Tiêu chí | Cách làm |
|---|---|---|
| 1 | Dockerfile | 2 stage `python:3.11-slim` (builder cài venv `/opt/venv`, runtime chỉ copy venv + `app/` + `utils/`), user `app` non-root, `HEALTHCHECK` gọi `/health`, `CMD sh -c "exec uvicorn … --port ${PORT:-8000}"` → uvicorn là PID 1 |
| 2 | Compose | `agent` build từ Dockerfile + `redis:7-alpine` có healthcheck; `REDIS_URL=redis://redis:6379/0`, `depends_on: service_healthy`; `.env` `required: false` |
| 3 | .dockerignore | loại `.env*` (giữ `.env.example`), `__pycache__`, `venv`, `.git`, `benchmark-observability/`… |
| 4 | /health | luôn 200, không gọi Redis |
| 5 | /ready | `redis.ping()` OK → 200, lỗi hoặc đang tắt → 503 |
| 6 | API key | `APIKeyHeader("X-API-Key")`, so sánh `hmac.compare_digest` với `AGENT_API_KEY`; thiếu/sai → 401 |
| 7 | Rate limit | Redis sorted set theo hash của API key: `ZREMRANGEBYSCORE` → `ZCARD` → `ZADD` → `EXPIRE`; vượt → 429 + `Retry-After` |
| 8 | Cost guard | `INCRBYFLOAT` theo ngày/tháng trong Redis; vượt → 402 |
| 9 | Config | `app/config.py` đọc mọi giá trị bằng `os.getenv`; `.env.example` liệt kê đủ |
| 10 | Logging | `JsonFormatter` (json.dumps) cho logger `agent`; middleware log mỗi request `{"event":"request","path","status","ms",…}` |
| 11 | Graceful shutdown | uvicorn xử lý SIGTERM; `lifespan` đánh dấu shutting_down (/ready → 503) và chờ in-flight về 0 (≤ 8s) |
| 12 | Deploy config | `railway.toml` (`builder = "DOCKERFILE"`, `healthcheckPath = "/health"`) + `render.yaml` (web docker + keyvalue Redis, `AGENT_API_KEY` `sync: false`) |

---

## AI log

| Lần | Hỏi AI gì | Nhận được gì | Mình tự kiểm tra / sửa thế nào |
|---|---|---|---|
| 1 | (Claude) Đọc README/CHECKPOINTS/RUBRIC và `check_production_ready.py`, sửa các TODO của Part 6 | Code cho `app/*.py`, Dockerfile, compose, `.dockerignore`, `.env.example`, `railway.toml`, `render.yaml` | Chạy `python check_production_ready.py` trong WSL2 + Docker → PASS 12/12, 43/43 checks (image 63 MB, build 22s, `docker stop` exit 0 trong 0.8s). Lần đầu chạy trên Windows PowerShell/Python 3.14 bị lỗi cài pydantic-core → chuyển sang WSL2 + Python 3.11 theo README. Đọc lại từng file, giải thích được rate limiter sorted set và vì sao /health không gọi Redis |
| 2 | (Claude) Sửa `KNOWLEDGE_BASE` cho 2 câu v2 sai, viết job CI quality gate, script chạy benchmark | 2 entry mới (JWT/API key, Kubernetes HPA), `.github/workflows/eval-quality-gate.yml`, `run_part7_local.sh`, `make_report_tables.py` | ⟪ Chạy eval: 23/23, 0 regression; kiểm tra keyword mới không trùng câu hỏi khác ⟫ |
| 3 | (Claude) Gợi ý câu trả lời lý thuyết Part 1–5 | Bản nháp các câu trả lời | ⟪ Tự đối chiếu với code từng thư mục, chạy lệnh và dán output của chính mình ⟫ |