#!/usr/bin/env bash
cd "$(dirname "$0")"
ok=0; bad=0
chk() { if [ -e "$1" ]; then echo "✅ $1"; ok=$((ok+1)); else echo "❌ $1"; bad=$((bad+1)); fi; }
chk MISSION_ANSWERS.md
chk DEPLOYMENT.md
chk BENCHMARK_REPORT.md
for c in 1 10 50 100; do chk reports/load_v2_c$c.json; done
for r in 0 0.03 0.1; do chk reports/load_v2_slow_$r.json; done
chk reports/eval_v1.json; chk reports/eval_v2.json; chk reports/eval_v2_fixed.json
chk benchmark-results/scale_1_stats.csv; chk benchmark-results/scale_3_stats.csv
for s in dashboard running test grafana-dashboard jaeger-slow-trace jaeger-error-trace prometheus-alert-firing; do
  chk screenshots/$s.png
done
chk 06-lab-complete/app/main.py
chk 06-lab-complete/railway.toml
echo
echo "Chỗ ⟪ … ⟫ chưa điền:"
grep -n "⟪" MISSION_ANSWERS.md DEPLOYMENT.md BENCHMARK_REPORT.md | grep -v "^[^:]*:[1-6]:>" | cut -c1-120
echo
git ls-files | grep -E '(^|/)\.env$' && echo "❌ CÓ FILE .env TRONG GIT!" || echo "✅ Không có .env trong git"
echo "------"
echo "Đủ: $ok · Thiếu: $bad"
