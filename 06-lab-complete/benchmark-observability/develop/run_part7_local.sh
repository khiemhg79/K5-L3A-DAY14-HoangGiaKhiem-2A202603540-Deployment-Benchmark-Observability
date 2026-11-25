#!/usr/bin/env bash
# ============================================================
# Part 7 — Bước 1 (CP7): chạy toàn bộ benchmark local và lưu report JSON vào reports/
#
#   cd 06-lab-complete/benchmark-observability/develop
#   pip install -r requirements.txt
#   bash run_part7_local.sh
# ============================================================
set -u
cd "$(dirname "$0")"
PY="${PYTHON:-python}"
mkdir -p reports logs

KB=utils/mock_llm.py
BACKUP=$(mktemp)
cp "$KB" "$BACKUP"
PIDS=()

cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  cp "$BACKUP" "$KB"          # luôn trả lại bản đã sửa KNOWLEDGE_BASE
  rm -f "$BACKUP"
}
trap cleanup EXIT

wait_up() {  # $1 = port
  for _ in $(seq 1 50); do
    curl -sf "http://localhost:$1/health" >/dev/null 2>&1 && return 0
    sleep 0.3
  done
  echo "❌ agent :$1 không lên — xem logs/" ; exit 1
}

start_agent() {  # $1 = version, $2 = port, $3.. = env thêm
  local ver=$1 port=$2; shift 2
  env AGENT_VERSION="$ver" PORT="$port" "$@" "$PY" app.py > "logs/agent_${ver}_${port}.log" 2>&1 &
  LAST_PID=$!
  PIDS+=("$LAST_PID")
  wait_up "$port"
}

stop_pid() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

echo "▶ 1. Tạm gỡ phần sửa KNOWLEDGE_BASE (v2 gốc)"
"$PY" - "$KB" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s2 = re.sub(r"\n    # Exercise 7\.3.*?# END Exercise 7\.3", "", s, flags=re.S)
open(p, "w", encoding="utf-8").write(s2)
print("   đã gỡ" if s2 != s else "   (không thấy marker — giữ nguyên)")
EOF

echo "▶ 2. Bật agent v1 :8001 và v2 :8002"
start_agent v1 8001; V1=$LAST_PID
start_agent v2 8002; V2=$LAST_PID

echo "▶ 3. Load test v2 — concurrency 1/10/50/100"
for c in 1 10 50 100; do
  "$PY" load_test.py --url http://localhost:8002 --requests 300 --concurrency "$c" --out "reports/load_v2_c${c}.json"
done

echo "▶ 4. So sánh MOCK_SLOW_RATE (concurrency 20)"
for rate in 0 0.03 0.1; do
  stop_pid "$V2"
  start_agent v2 8002 MOCK_SLOW_RATE="$rate"; V2=$LAST_PID
  "$PY" load_test.py --url http://localhost:8002 --requests 300 --concurrency 20 --out "reports/load_v2_slow_${rate}.json"
done
stop_pid "$V2"
start_agent v2 8002; V2=$LAST_PID

echo "▶ 5. Eval v1 và v2 (KNOWLEDGE_BASE gốc)"
"$PY" eval/run_eval.py --url http://localhost:8001 --out reports/eval_v1.json
"$PY" eval/run_eval.py --url http://localhost:8002 --out reports/eval_v2.json --baseline reports/eval_v1.json

echo "▶ 6. Quality gate: v1 so với baseline v2 (mong đợi exit code 1)"
"$PY" eval/run_eval.py --url http://localhost:8001 --baseline reports/eval_v2.json
echo "   exit code = $?" | tee reports/quality_gate_v1_vs_v2.txt

echo "▶ 7. Khôi phục KNOWLEDGE_BASE đã sửa, restart v2, eval cuối"
cp "$BACKUP" "$KB"
stop_pid "$V2"
start_agent v2 8002; V2=$LAST_PID
"$PY" eval/run_eval.py --url http://localhost:8002 --min-accuracy 1.0 \
    --baseline reports/eval_v2.json --out reports/eval_v2_fixed.json
echo "   exit code = $?"

echo
echo "✅ Xong. File trong $(pwd)/reports:"
ls -1 reports