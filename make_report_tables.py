"""In các bảng số liệu cho BENCHMARK_REPORT.md, đọc trực tiếp từ JSON/CSV đã chạy.
Chạy từ gốc repo:  python make_report_tables.py
"""
import argparse, csv, json, os


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def load_tables(rep):
    print("### 2.1 Concurrency vs latency (agent v2)\n")
    print("| Concurrency | RPS | p50 (ms) | p95 (ms) | p99 (ms) | Error rate | SLO |")
    print("|---|---|---|---|---|---|---|")
    for c in (1, 10, 50, 100):
        d = load(os.path.join(rep, f"load_v2_c{c}.json"))
        if not d:
            print(f"| {c} | (thiếu load_v2_c{c}.json) | | | | | |"); continue
        l = d["latency_ms"]
        print(f"| {c} | {d['rps']} | {l['p50']} | {l['p95']} | {l['p99']} | "
              f"{d['error_rate'] * 100:.2f}% | {'✅ PASS' if d['slo']['passed'] else '❌ FAIL'} |")
    print("\n### 2.2 Tail latency (concurrency 20)\n")
    print("| `MOCK_SLOW_RATE` | avg (ms) | p95 (ms) | p99 (ms) |")
    print("|---|---|---|---|")
    for rate, label in (("0", "0"), ("0.03", "0.03 (mặc định)"), ("0.1", "0.1")):
        d = load(os.path.join(rep, f"load_v2_slow_{rate}.json"))
        if not d:
            print(f"| {label} | (thiếu file) | | |"); continue
        l = d["latency_ms"]
        print(f"| {label} | {l['avg']} | {l['p95']} | {l['p99']} |")


def eval_tables(rep):
    files = [("Agent v1", "eval_v1.json"), ("Agent v2", "eval_v2.json"),
             ("Agent v2 (sau khi sửa KB)", "eval_v2_fixed.json")]
    data = [load(os.path.join(rep, f)) for _, f in files]
    print("\n## 3. Benchmark chất lượng\n")
    print("| Chỉ số | " + " | ".join(n for n, _ in files) + " |")
    print("|---|---|---|---|")
    def row(name, fn):
        print(f"| {name} | " + " | ".join(fn(d) if d else "(thiếu)" for d in data) + " |")
    row("Accuracy", lambda d: f"{d['accuracy'] * 100:.1f}% ({d['passed']}/{d['total']})")
    row("Avg tokens / câu", lambda d: str(d["avg_tokens"]))
    row("Tổng cost (USD)", lambda d: f"{d['total_cost_usd']:.6f}")
    row("Cost / câu đúng (USD)", lambda d: f"{d['cost_per_correct_usd']:.8f}" if d["cost_per_correct_usd"] else "—")
    row("Quality gate", lambda d: ("PASS" if d["quality_gate"]["passed"] else "FAIL")
        + f" (min {d['quality_gate']['min_accuracy'] * 100:.0f}%)")


def locust_tables(res):
    print("\n## 5. Benchmark scaling (Locust headless)\n")
    print("| Số instance | RPS | p50 (ms) | p95 (ms) | p99 (ms) | Failures |")
    print("|---|---|---|---|---|---|")
    for n in (1, 3):
        path = os.path.join(res, f"scale_{n}_stats.csv")
        try:
            with open(path, encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
        except OSError:
            print(f"| {n} | (thiếu scale_{n}_stats.csv) | | | | |"); continue
        agg = next((r for r in rows if r.get("Name") == "Aggregated"), rows[-1])
        reqs, fails = int(agg["Request Count"]), int(agg["Failure Count"])
        print(f"| {n} | {float(agg['Requests/s']):.2f} | {agg['50%']} | {agg['95%']} | {agg['99%']} | "
              f"{fails}/{reqs} ({fails / reqs * 100 if reqs else 0:.2f}%) |")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--reports", default="reports")
    p.add_argument("--results", default="benchmark-results")
    a = p.parse_args()
    load_tables(a.reports); eval_tables(a.reports); locust_tables(a.results)
