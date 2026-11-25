#!/usr/bin/env bash
# ============================================================
# Chạy toàn bộ lệnh test của Part 1, 2, 4, 5 và lưu output vào evidence/part1_5_output.txt
# để dán vào MISSION_ANSWERS.md.
#
#   cd <gốc repo>
#   source ~/venvs/day14/bin/activate
#   bash collect_part1_5.sh            # đầy đủ (cần Docker cho Part 2 và 5.4–5.5)
#   bash collect_part1_5.sh --no-docker
# ============================================================
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
mkdir -p evidence
OUT="$ROOT/evidence/part1_5_output.txt"
: > "$OUT"
USE_DOCKER=1
[ "${1:-}" = "--no-docker" ] && USE_DOCKER=0
PY="${PYTHON:-python}"
PID=""

say()  { echo -e "$*" | tee -a "$OUT"; }
run()  { say "\n\$ $*"; bash -c "$*" 2>&1 | tee -a "$OUT"; }
hdr()  { say "\n\n==================== $* ===================="; }

wait_port() {  # $1 = url
  for _ in $(seq 1 60); do curl -s -o /dev/null "$1" && return 0; sleep 0.5; done
  say "!! server không lên: $1"; return 1
}
start() {      # $1 = thư mục, $2.. = lệnh (có thể kèm biến môi trường)
  local dir=$1; shift
  ( cd "$dir" && exec setsid env "$@" ) > /tmp/p15_server.log 2>&1 &
  PID=$!
}
stop() {
  [ -n "$PID" ] && kill -TERM -- -"$PID" 2>/dev/null
  sleep 1; [ -n "$PID" ] && kill -KILL -- -"$PID" 2>/dev/null
  wait "$PID" 2>/dev/null; PID=""
}
trap stop EXIT
install() { "$PY" -m pip install -q -r "$1/requirements.txt" >/dev/null 2>&1; }

# ─────────────────────────── Part 1 ───────────────────────────
hdr "PART 1.2 — develop (question qua query)"
install 01-localhost-vs-production/develop
start 01-localhost-vs-production/develop "$PY" app.py
wait_port http://localhost:8000/ && {
  run 'curl -s -X POST "http://localhost:8000/ask?question=Hello"; echo'
  run 'curl -s -o /dev/null -w "GET /health -> %{http_code}\n" http://localhost:8000/health'
}
say "\n-- log server develop (thấy print lộ API key):"; tail -n 5 /tmp/p15_server.log | tee -a "$OUT"
stop

hdr "PART 1.3 — production (12-factor)"
install 01-localhost-vs-production/production
start 01-localhost-vs-production/production PORT=8000 ENVIRONMENT=development "$PY" app.py
wait_port http://localhost:8000/health && {
  run 'curl -s http://localhost:8000/health; echo'
  run 'curl -s http://localhost:8000/ready; echo'
  run "curl -s -X POST http://localhost:8000/ask -H 'Content-Type: application/json' -d '{\"question\": \"Hello\"}'; echo"
}
say "\n-- log server production (JSON, không có secret):"; tail -n 5 /tmp/p15_server.log | tee -a "$OUT"
stop

# ─────────────────────────── Part 2 ───────────────────────────
if [ $USE_DOCKER = 1 ]; then
  hdr "PART 2.2 — build + run image develop"
  run 'docker build -q -f 02-docker/develop/Dockerfile -t my-agent:develop .'
  docker rm -f p2dev >/dev/null 2>&1
  run 'docker run -d --rm --name p2dev -p 8000:8000 my-agent:develop'
  wait_port http://localhost:8000/ && \
    run 'curl -s -X POST "http://localhost:8000/ask?question=What%20is%20Docker"; echo'
  docker stop p2dev >/dev/null 2>&1

  hdr "PART 2.3 — build image production (multi-stage) + so sánh kích thước"
  run 'docker build -q -f 02-docker/production/Dockerfile -t my-agent:advanced .'
  run 'docker images my-agent --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"'
  run 'docker image inspect -f "{{.RepoTags}} {{.Size}}" my-agent:develop my-agent:advanced | awk "{printf \"%s %.0f MB\n\", \$1, \$2/1024/1024}"'

  hdr "PART 2.4 — Docker Compose stack (nginx + agent + redis + qdrant)"
  touch 02-docker/production/.env.local
  run 'cd 02-docker/production && docker compose -p k5-day14-docker up -d --build 2>&1 | tail -n 8'
  sleep 8
  run 'cd 02-docker/production && docker compose -p k5-day14-docker ps --format "table {{.Service}}\t{{.State}}\t{{.Ports}}"'
  run 'curl -s http://localhost/health; echo'
  run "curl -s -X POST http://localhost/ask -H 'Content-Type: application/json' -d '{\"question\": \"Explain microservices\"}'; echo"
  run 'cd 02-docker/production && docker compose -p k5-day14-docker down >/dev/null 2>&1; echo "stack down"'
else
  hdr "PART 2 — bỏ qua (--no-docker)"
fi

# ─────────────────────────── Part 4 ───────────────────────────
hdr "PART 4.1 — API key (develop)"
install 04-api-gateway/develop
start 04-api-gateway/develop AGENT_API_KEY=secret-key-123 "$PY" app.py
wait_port http://localhost:8000/ && {
  run "curl -s -i -X POST http://localhost:8000/ask -H 'Content-Type: application/json' -d '{\"question\": \"Hello\"}' | grep -E '^HTTP|detail'"
  run "curl -s -i -X POST http://localhost:8000/ask -H 'X-API-Key: wrong-key' -H 'Content-Type: application/json' -d '{\"question\": \"Hello\"}' | grep -E '^HTTP|detail'"
  run "curl -s -i -X POST http://localhost:8000/ask -H 'X-API-Key: secret-key-123' -H 'Content-Type: application/json' -d '{\"question\": \"Hello\"}' | grep -E '^HTTP|answer'"
}
stop

hdr "PART 4.2–4.3 — JWT + rate limit (production)"
install 04-api-gateway/production
start 04-api-gateway/production "$PY" app.py
wait_port http://localhost:8000/health && {
  RESP=$(curl -s -X POST http://localhost:8000/auth/token -H 'Content-Type: application/json' \
         -d '{"username":"student","password":"demo123"}')
  TOKEN=$(echo "$RESP" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
  say "\n\$ curl -X POST /auth/token -d '{\"username\":\"student\",\"password\":\"demo123\"}'"
  say "$(echo "$RESP" | sed -E 's/eyJ[A-Za-z0-9_.-]+/eyJ…<đã che>/g')"
  say "\n\$ curl -i /ask KHÔNG có token"
  curl -s -i -X POST http://localhost:8000/ask -H 'Content-Type: application/json' -d '{"question":"Hi"}' | grep -E '^HTTP|detail' | tee -a "$OUT"
  say "\n\$ curl -i /ask có token (Authorization: Bearer eyJ…<đã che>)"
  curl -s -i -X POST http://localhost:8000/ask -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
       -d '{"question":"Explain JWT"}' | grep -E '^HTTP|answer' | tee -a "$OUT"
  say "\n\$ for i in {1..20}; do curl … /ask (Bearer token) …; done"
  for i in $(seq 1 20); do
    code=$(curl -s -o /tmp/p15_body -w '%{http_code}' -X POST http://localhost:8000/ask \
           -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"question\":\"Test $i\"}")
    say "$i: HTTP $code"
    [ "$code" = 429 ] && last429=$(cat /tmp/p15_body)
  done
  [ -n "${last429:-}" ] && say "body 429: $last429"
  say "\n\$ curl /me/usage (cost guard — usage của user)"
  curl -s http://localhost:8000/me/usage -H "Authorization: Bearer $TOKEN" | tee -a "$OUT"; echo | tee -a "$OUT"
}
stop

# ─────────────────────────── Part 5 ───────────────────────────
hdr "PART 5.1–5.2 — health/ready + graceful shutdown (develop)"
install 05-scaling-reliability/develop
start 05-scaling-reliability/develop "$PY" app.py
wait_port http://localhost:8000/health && {
  run 'curl -s http://localhost:8000/health; echo'
  run 'curl -s http://localhost:8000/ready; echo'
  say "\n\$ curl -X POST '/ask?question=Long task' &  rồi ngay lập tức kill -TERM <pid>"
  ( curl -s -w '\n[request in-flight -> HTTP %{http_code}]\n' -X POST "http://localhost:8000/ask?question=Long%20task" >> "$OUT" ) &
  CURL=$!
  sleep 0.2
  kill -TERM -- -"$PID" 2>/dev/null
  wait $CURL
  wait "$PID" 2>/dev/null; say "[server exit code: $?]"; PID=""
  say "\n-- log server khi tắt:"; grep -iE "shutdown|in-flight|SIGTERM|signal|complete|Waiting" /tmp/p15_server.log | tail -n 8 | tee -a "$OUT"
}
stop

if [ $USE_DOCKER = 1 ]; then
  hdr "PART 5.4–5.5 — 3 instance + Nginx + Redis, test stateless"
  touch 05-scaling-reliability/production/.env.local
  run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling up -d --build --scale agent=3 2>&1 | tail -n 8'
  sleep 10
  run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling ps --format "table {{.Name}}\t{{.State}}"'
  run 'cd 05-scaling-reliability/production && python test_stateless.py'
  run 'for i in 1 2 3 4 5 6; do curl -s -o /dev/null -D - http://localhost:8080/health | grep -i x-served-by; done'
  run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling down >/dev/null 2>&1; echo "stack down"'
else
  hdr "PART 5.4–5.5 — bỏ qua (--no-docker)"
fi

say "\n\n✅ Xong. Toàn bộ output: $OUT"