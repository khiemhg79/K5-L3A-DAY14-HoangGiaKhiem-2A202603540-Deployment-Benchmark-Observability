#!/usr/bin/env bash
# ============================================================
# Part 7 — Bước 2 (CP8): Observability stack, chạy từ gốc repo:
#
#   source ~/venvs/day14/bin/activate
#   bash run_part7_stack.sh
#
# Script tự làm:
#   1. Bật stack (agent + nginx + prometheus + grafana + jaeger), Locust headless scale 1 → scale 3
#      → benchmark-results/scale_1_stats.csv, scale_3_stats.csv
#   2. Tạo tải nền, tìm trace chậm nhất + 1 trace lỗi trong Jaeger, lấy dòng log JSON cùng trace_id
#   3. Bơm lỗi (MOCK_ERROR_RATE=0.2, MOCK_SLOW_RATE=0.3), đo thời gian tới lúc 2 alert FIRING
#   4. Copy CSV ra gốc repo, ghi evidence/part7_stack.txt, dọn stack
# Ở mỗi chỗ cần chụp ảnh, script DỪNG và chờ bạn bấm Enter.
# ============================================================
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
STACK="$ROOT/06-lab-complete/benchmark-observability/production"
P="k5-day14-observability"
DC="docker compose -p $P"
PY="${PYTHON:-python}"
OUT="$ROOT/evidence/part7_stack.txt"
mkdir -p "$ROOT/evidence" "$ROOT/screenshots" "$ROOT/benchmark-results"
: > "$OUT"
say()   { echo -e "$*" | tee -a "$OUT"; }
pause() { echo; echo "📸 $*"; read -r -p "   → Chụp xong thì bấm Enter để tiếp tục... " _; }
cd "$STACK"
touch .env 2>/dev/null

cleanup_load() { docker rm -f p7-load >/dev/null 2>&1; }
trap cleanup_load EXIT

wait_http() { for _ in $(seq 1 90); do curl -s -o /dev/null "$1" && return 0; sleep 2; done; return 1; }

# ───────────────────── 1. Stack + benchmark scaling ─────────────────────
say "==================== 1. Bật stack (1 instance) ===================="
$DC up -d --build --scale agent=1 2>&1 | tail -n 5
wait_http http://localhost:8080/health || { echo "❌ nginx/agent không lên"; exit 1; }
wait_http http://localhost:9090/-/ready
sleep 15
say "$($DC ps --format 'table {{.Service}}\t{{.State}}')"

say "\n==================== 1a. Locust headless — 1 instance (2 phút) ===================="
$DC run --rm locust -f /mnt/locust/locustfile.py --host http://nginx \
   --headless -u 100 -r 10 -t 2m --csv /mnt/results/scale_1 2>&1 | tail -n 12 | tee -a "$OUT"

say "\n==================== 1b. Scale lên 3 instance ===================="
$DC up -d --scale agent=3 2>&1 | tail -n 3
sleep 20
say "$($DC ps agent --format 'table {{.Name}}\t{{.State}}')"

say "\n==================== 1c. Locust headless — 3 instance (2 phút) ===================="
$DC run --rm locust -f /mnt/locust/locustfile.py --host http://nginx \
   --headless -u 100 -r 10 -t 2m --csv /mnt/results/scale_3 2>&1 | tail -n 12 | tee -a "$OUT"

cp benchmark-results/scale_1_stats.csv benchmark-results/scale_3_stats.csv "$ROOT/benchmark-results/" 2>/dev/null \
  && say "\n✅ Đã copy scale_1_stats.csv, scale_3_stats.csv → benchmark-results/"

# ───────────────────── 2. Tải nền + Grafana + Jaeger ─────────────────────
say "\n==================== 2. Tải nền 30 user (chạy suốt phần còn lại) ===================="
cleanup_load
$DC run -d --name p7-load locust -f /mnt/locust/locustfile.py --host http://nginx \
   --headless -u 30 -r 5 -t 30m >/dev/null
sleep 60

pause "Mở http://localhost:3000 (dashboard 'Day 14 — AI Agent Overview', góc trên phải chọn 'Last 15 minutes').
   Chụp cả trang → lưu screenshots/grafana-dashboard.png
   Ghi lại p95 và avg đang hiện (cho Exercise 7.4)."

say "\n==================== 2b. Trace chậm nhất + trace lỗi (Jaeger API) ===================="
"$PY" - "$OUT" <<'EOF'
import json, sys, urllib.request, urllib.parse
out = open(sys.argv[1], "a", encoding="utf-8")
def p(s=""):
    print(s); out.write(s + "\n")
base = "http://localhost:16686/api/traces"
def get(params):
    with urllib.request.urlopen(base + "?" + urllib.parse.urlencode(params), timeout=20) as r:
        return json.load(r).get("data") or []
def summary(t):
    spans = t["spans"]
    root = max(spans, key=lambda s: s["duration"])
    parts = sorted(spans, key=lambda s: -s["duration"])
    return root["duration"] / 1000, [(s["operationName"], s["duration"] / 1000) for s in parts[:4]]
slow = get({"service": "observable-agent", "lookback": "1h", "limit": 500, "minDuration": "1s"})
if slow:
    t = max(slow, key=lambda t: max(s["duration"] for s in t["spans"]))
    total, parts = summary(t)
    p(f"SLOW_TRACE_ID={t['traceID']}")
    p(f"Tổng thời gian: {total:.1f} ms")
    for name, ms in parts:
        p(f"  span {name:<28} {ms:9.1f} ms  ({ms / total * 100:5.1f}%)")
    p(f"Link: http://localhost:16686/trace/{t['traceID']}")
else:
    p("Không tìm thấy trace > 1s (tải chưa đủ lâu?)")
err = get({"service": "observable-agent", "lookback": "1h", "limit": 50, "tags": json.dumps({"error": "true"})})
if err:
    t = err[0]
    p(f"\nERROR_TRACE_ID={t['traceID']}")
    p(f"Link: http://localhost:16686/trace/{t['traceID']}")
else:
    p("\nKhông tìm thấy trace lỗi — đợi thêm vài phút (mock lỗi ~1%)")
EOF

SLOW_ID=$(grep -m1 '^SLOW_TRACE_ID=' "$OUT" | cut -d= -f2)
ERR_ID=$(grep -m1 '^ERROR_TRACE_ID=' "$OUT" | cut -d= -f2)
if [ -n "$SLOW_ID" ]; then
  say "\n-- Dòng log JSON có trace_id của trace chậm:"
  $DC logs agent --no-log-prefix 2>/dev/null | grep "$SLOW_ID" | head -n 3 | tee -a "$OUT"
fi
if [ -n "$ERR_ID" ]; then
  say "\n-- Dòng log JSON có trace_id của trace lỗi:"
  $DC logs agent --no-log-prefix 2>/dev/null | grep "$ERR_ID" | head -n 3 | tee -a "$OUT"
fi

pause "Mở link trace CHẬM ở trên (hoặc Jaeger → Service observable-agent → Find Traces → sort 'Longest First').
   Chụp màn hình thấy các span và span 'chat mock-llm-small' dài nhất → lưu screenshots/jaeger-slow-trace.png"
pause "Mở link trace LỖI ở trên (hoặc Find Traces với Tags: error=true), bấm vào span lỗi để thấy event 'exception'.
   Chụp → lưu screenshots/jaeger-error-trace.png"

# ───────────────────── 3. Alerts ─────────────────────
say "\n==================== 3. Bơm lỗi: MOCK_ERROR_RATE=0.2, MOCK_SLOW_RATE=0.3 ===================="
T0=$(date +%s)
say "Thời điểm đổi cấu hình: $(date '+%H:%M:%S')"
MOCK_ERROR_RATE=0.2 MOCK_SLOW_RATE=0.3 $DC up -d --scale agent=3 agent 2>&1 | tail -n 3

declare -A FIRED
for _ in $(seq 1 90); do      # tối đa ~7,5 phút
  STATES=$(curl -s http://localhost:9090/api/v1/alerts | "$PY" -c '
import json,sys
for a in json.load(sys.stdin)["data"]["alerts"]:
    print(a["labels"]["alertname"], a["state"])' 2>/dev/null)
  while read -r name state; do
    [ -z "$name" ] && continue
    if [ "$state" = "firing" ] && [ -z "${FIRED[$name]:-}" ]; then
      FIRED[$name]=$(( $(date +%s) - T0 ))
      say "🔥 $name FIRING sau ${FIRED[$name]} giây ($(date '+%H:%M:%S'))"
    fi
  done <<< "$STATES"
  [ -n "${FIRED[AgentHighErrorRate]:-}" ] && [ -n "${FIRED[AgentHighLatencyP95]:-}" ] && break
  sleep 5
done
say "\nTrạng thái alert hiện tại:"
curl -s http://localhost:9090/api/v1/alerts | "$PY" -c '
import json,sys
for a in json.load(sys.stdin)["data"]["alerts"]:
    print(" -", a["labels"]["alertname"], a["state"], a.get("activeAt",""))' | tee -a "$OUT"

pause "Mở http://localhost:9090/alerts — thấy AgentHighErrorRate và AgentHighLatencyP95 cùng FIRING (đỏ).
   Chụp → lưu screenshots/prometheus-alert-firing.png
   (Có thể chụp thêm Grafana lúc này: panel Error rate / p95 đỏ — không bắt buộc.)"

say "\n==================== 3b. Trả cấu hình về mặc định ===================="
$DC up -d --scale agent=3 agent 2>&1 | tail -n 2

# ───────────────────── 4. Dọn ─────────────────────
cleanup_load
say "\n==================== 4. Dọn stack ===================="
read -r -p "Đã chụp đủ 4 ảnh Part 7? Bấm Enter để tắt stack (docker compose down -v)... " _
$DC down -v 2>&1 | tail -n 2
say "\n✅ Xong. Bằng chứng: $OUT"
say "   CSV: $ROOT/benchmark-results/"
ls -1 "$ROOT/screenshots" 2>/dev/null | sed 's/^/   ảnh: /'