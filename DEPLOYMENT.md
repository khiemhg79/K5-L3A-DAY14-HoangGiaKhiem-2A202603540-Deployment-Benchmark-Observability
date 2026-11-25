# Deployment Information

## Public URL
https://agent-production-d3565445.up.railway.app

## Platform
**Railway**. Project gồm 2 service:
- `agent`: build từ `06-lab-complete/Dockerfile` (multi-stage, `python:3.11-slim`), cấu hình theo `06-lab-complete/railway.toml` (`builder = "DOCKERFILE"`, `healthcheckPath = "/health"`)
- `Redis`: database Redis của Railway, dùng cho rate limit và cost guard

Railway tự cấp `PORT=8080`; `CMD` trong Dockerfile đọc `${PORT:-8000}`, nên uvicorn chạy ở 8080 và domain public trỏ vào port 8080. Log lúc khởi động: `event="startup" environment="production" port=8080 redis_ok=true`.

## Cách deploy (Railway CLI)

```bash
npm i -g @railway/cli
railway login --browserless
cd 06-lab-complete
railway link                                   # chọn project → production
railway add --database redis                   # service Redis
railway add --service agent                    # service rỗng tên "agent"

# Secret tạo ngẫu nhiên, đặt bằng biến môi trường trên Railway, không ghi trong code/repo
export AGENT_API_KEY=$(openssl rand -hex 16)
railway variables --service agent \
  --set "AGENT_API_KEY=$AGENT_API_KEY" \
  --set 'REDIS_URL=${{Redis.REDIS_URL}}' \
  --set "ENVIRONMENT=production" \
  --set "RATE_LIMIT_PER_MINUTE=10"

railway up --service agent                     # build Dockerfile + deploy
railway domain --service agent --port 8080     # tạo public URL
```

Ghi chú: lần đầu `railway up` từ trong repo bị lỗi build `header key "exclude-patterns" contains value with non-printable ASCII characters`. Nguyên nhân là các file ignore của repo (`.gitignore`, `.dockerignore`) có comment chứa ký tự không phải ASCII (tiếng Việt có dấu, ký tự kẻ `──`). Builder của Railway gửi danh sách pattern trong một HTTP header chỉ chấp nhận ASCII. Cách khắc phục: deploy từ một bản sao sạch của `06-lab-complete` (gồm `app/`, `utils/`, `Dockerfile`, `requirements.txt`, `railway.toml` và một `.dockerignore` chỉ có ASCII).

## Test Commands

```bash
export BASE=https://agent-production-d3565445.up.railway.app
export AGENT_API_KEY=<key đã đặt trên Railway>     # không ghi vào file này

curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/health"     # 200
curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/ready"      # 200
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$BASE/ask" -H 'Content-Type: application/json' -d '{"question":"Hello"}'   # 401
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$BASE/ask" -H 'Content-Type: application/json' -H "X-API-Key: $AGENT_API_KEY" -d '{"question":"Hello"}'   # 200
```

Kết quả:

```
200
200
401
200
```

Kiểm tra bằng script chấm:

```bash
python check_production_ready.py --public-url https://agent-production-d3565445.up.railway.app
```

```
✅ Public URL: GET https://agent-production-d3565445.up.railway.app/health → 200
```

### Rate limit trên cloud

```bash
for i in $(seq 1 12); do curl -s -o /dev/null -w "$i: %{http_code}\n" -X POST "$BASE/ask" \
  -H 'Content-Type: application/json' -H "X-API-Key: $AGENT_API_KEY" -d '{"question":"test"}'; done
```

```
1: 200
2: 200
3: 200
4: 200
5: 200
6: 200
7: 200
8: 200
9: 200
10: 429
11: 429
12: 429
```

Đúng 10 request / 60 giây cho mỗi API key. Request thử ngay trước vòng lặp đã tính 1/10, nên lần thứ 10 trong vòng lặp bị 429. State nằm trong Redis của Railway, nên mọi worker dùng chung một bộ đếm.

## Environment Variables Set (trên Railway, không ghi trong code)
- `PORT`: Railway tự cấp (8080)
- `REDIS_URL` = `${{Redis.REDIS_URL}}` (tham chiếu tới service Redis trong cùng project)
- `AGENT_API_KEY`: secret, sinh bằng `openssl rand -hex 16`, chỉ lưu trên Railway
- `ENVIRONMENT=production`
- `RATE_LIMIT_PER_MINUTE=10`
- `DAILY_BUDGET_USD`, `MONTHLY_BUDGET_USD`: dùng mặc định trong `config.py` (1.0 / 10.0)

## Screenshots
- [Deployment dashboard](screenshots/dashboard.png)
- [Service running](screenshots/running.png)
- [Test results](screenshots/test.png)