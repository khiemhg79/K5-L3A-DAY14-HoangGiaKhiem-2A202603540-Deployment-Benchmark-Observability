# Benchmark & Observability Report — Day 14

> Mọi con số lấy từ report JSON / CSV / screenshot thật. Các bảng số ở mục 2, 3, 5 được in bằng
> `python make_report_tables.py` (đọc trực tiếp `reports/*.json` và `benchmark-results/*.csv`) rồi dán vào đây.
> Chỗ `⟪ … ⟫` là phần phải điền theo kết quả chạy của chính mình.

**Họ tên:** Hoàng Gia Khiêm (2A202603540)
**Ngày chạy:** 2026-11-25
**Môi trường:** Windows + WSL2 (Ubuntu), Python 3.11 (venv), Docker Desktop 29.2.1. Code nằm ở ổ D (`/mnt/d/...`). Agent và client load test chạy cùng một máy

---

## 1. SLO của agent

| SLI | SLO | Lý do chọn ngưỡng này |
|---|---|---|
| p95 latency `/ask` | < 500 ms | LLM mock mất ~150–250 ms/câu; 500 ms còn dư cho mạng + retrieval, vẫn cảm giác "tức thì" với chat. Đặt theo p95 vì average che mất tail latency |
| Error rate `/ask` | < 2 % | Upstream LLM tự lỗi ~1 % (`MOCK_ERROR_RATE=0.01`); 2 % = error budget gấp đôi mức nền, vượt là có sự cố thật |
| Accuracy trên golden dataset | ≥ 85 % (CI), mục tiêu 100 % | 23 câu → mỗi câu ≈ 4,3 %; 85 % cho phép sai tối đa 3 câu, và gate còn chặn mọi regression so với baseline |

---

## 2. Benchmark hiệu năng (develop, `load_test.py`)

### 2.1 Concurrency vs latency (agent v2, 300 request)

Nguồn: `reports/load_v2_c1.json`, `load_v2_c10.json`, `load_v2_c50.json`, `load_v2_c100.json`.

| Concurrency | RPS | p50 (ms) | p95 (ms) | p99 (ms) | Error rate | SLO |
|---|---|---|---|---|---|---|
| 1 | 4.22 | 187.2 | 221.8 | 1709.1 | 1.00% | ✅ PASS |
| 10 | 34.97 | 191.6 | 221.1 | 1710.0 | 0.67% | ✅ PASS |
| 50 | 102.27 | 201.9 | 274.8 | 1707.5 | 1.67% | ✅ PASS |
| 100 | 53.32 | 415.0 | 3588.1 | 3845.5 | 0.67% | ❌ FAIL (p95) |

**Nhận xét:** RPS **chỉ tăng gần tuyến tính ở concurrency thấp**, rồi sụt khi quá tải:

- Từ 1 lên 10, RPS tăng 8,3 lần (4,22 → 34,97); từ 10 lên 50, tăng 2,9 lần (→ 102,27). Trong vùng này p50 gần như giữ nguyên (~190–200 ms), nên throughput ≈ concurrency / latency (Little's law): request được xử lý song song thật, vì mock LLM dùng `asyncio.sleep` và không chiếm CPU khi chờ.
- Ở mức 100, RPS **giảm** xuống 53,32 và p50 tăng gấp đôi (415 ms), p95 lên 3588 ms. Agent chỉ có 1 process uvicorn (1 event loop), cùng chia CPU với client load test trên một máy WSL. Phần việc thật sự tốn CPU (parse JSON, middleware, Prometheus metrics, log) bị xếp hàng, nên latency tăng nhanh hơn concurrency, và throughput giảm thay vì tăng. Điểm bão hoà nằm khoảng 50–100 concurrent request; muốn hơn thì phải scale (thêm worker/instance).
- p99 luôn khoảng 1,7 s ở mọi mức. Đó là 3% request bị chậm thêm 1,5 s (`MOCK_SLOW_RATE=0.03`), không phụ thuộc tải. Error rate (0,67–1,67%) là lỗi 503 giả lập từ LLM upstream (`MOCK_ERROR_RATE=0.01`), không do quá tải.

### 2.2 Tail latency (concurrency 20, 300 request)

Nguồn: `reports/load_v2_slow_0.json`, `load_v2_slow_0.03.json`, `load_v2_slow_0.1.json` (300 request, concurrency 20).

| `MOCK_SLOW_RATE` | avg (ms) | p95 (ms) | p99 (ms) |
|---|---|---|---|
| 0 | 191.1 | 219.9 | 233.5 |
| 0.03 (mặc định) | 267.3 | 660.0 | 1707.8 |
| 0.1 | 350.6 | 1697.5 | 1715.3 |

**Nhận xét:**

- **p99 nhạy nhất.** Chỉ cần 3% request chậm, p99 đã tăng 7,3 lần (233,5 → 1707,8 ms), vì đúng nhóm 3% đó chiếm phần đuôi của phân phối. Với 10% request chậm, **p95** cũng nhảy lên 1697,5 ms (gấp 7,7 lần), vì tỉ lệ chậm đã vượt 5%.
- Ở mức 0.03, p95 = 660 ms (vượt SLO 500 ms). 3% chậm cộng 1,67% lỗi sát ngưỡng 5%, nên p95 rơi đúng vào ranh giới giữa nhóm nhanh và nhóm chậm. Lần chạy khác có thể ra ~220 ms; cùng một cấu hình mà p95 dao động mạnh như vậy nghĩa là SLO đang sát giới hạn.
- **avg ít nhạy nhất:** chỉ tăng 1,4 lần (191 → 267 ms) ở mức 0.03 và 1,8 lần ở mức 0.1. Vì 97% request nhanh pha loãng giá trị trung bình, avg trông "ổn" trong khi cứ 100 người thì có vài người chờ gần 2 giây. Đặt SLO theo average sẽ không bao giờ thấy được nhóm người dùng này, nên SLO phải đặt theo p95/p99.
- Throughput cũng giảm theo (101,66 → 57,49 → 46,98 req/s), vì request chậm giữ chỗ trong 20 slot concurrency lâu hơn.

---

## 3. Benchmark chất lượng (develop, `eval/run_eval.py`)

Nguồn: `reports/eval_v1.json`, `eval_v2.json`, `eval_v2_fixed.json` (golden dataset 23 câu).

| Chỉ số | Agent v1 | Agent v2 | Agent v2 (sau khi sửa KB) |
|---|---|---|---|
| Accuracy | 4.3% (1/23) | 91.3% (21/23) | 100.0% (23/23) |
| Avg tokens / câu | 57.2 | 108.8 | 116.5 |
| Tổng cost (USD) | 0.000406 | 0.000757 | 0.000815 |
| Cost / câu đúng (USD) | 0.00040575 | 0.00003607 | 0.00003544 |
| Latency p95 eval (ms) | 188.6 | 220.3 | 230.1 |
| Quality gate | FAIL (min 80%) | PASS (min 80%) | PASS (min 100%, 0 regression) |

**Những câu v2 trả lời sai ban đầu và cách sửa:**

| ID | Keyword bị thiếu | Đã sửa gì |
|---|---|---|
| security-02 | token, hết hạn, chữ ký | Thêm entry `(["jwt", "api key", "json web token"], …)` vào `KNOWLEDGE_BASE`: so sánh API key (chuỗi cố định, không hết hạn) với JWT (token có chữ ký số, có thời gian hết hạn `exp`) |
| scaling-03 | cpu, memory, custom metrics | Thêm entry `(["hpa", "kubernetes", "autoscaler", "autoscaling"], …)`: HPA scale theo CPU, memory và custom metrics |

Từ khoá kích hoạt được chọn để **không trùng** câu hỏi khác trong golden dataset (không dùng "scale", "token"…), nên không câu nào khác bị đổi tài liệu được retrieve → 0 regression. Bản sửa chép sang cả `production/utils/mock_llm.py`.

**Quality gate:** `python eval/run_eval.py --url http://localhost:8001 --baseline reports/eval_v2.json` (v1 so với baseline v2) trả **exit code 1**: accuracy 4,3% < 80% và 20 câu regression (`reports/quality_gate_v1_vs_v2.txt`). Eval cuối của v2 sau khi sửa trả **exit code 0**, với 2 câu được cải thiện và 0 regression. Job `.github/workflows/eval-quality-gate.yml` chạy agent v2 rồi `run_eval.py --min-accuracy 0.85`; exit code ≠ 0 làm job fail, kết hợp branch protection "Require status checks to pass" → PR không merge được.

**Trade-off v1 / v2:**

- **Chi phí:** v2 tốn 1,9 lần token mỗi câu (57,2 → 108,8) và tổng cost 1,86 lần (0,000406 → 0,000757 USD), vì prompt có thêm context từ retrieval.
- **Latency:** p95 eval tăng 31,7 ms (188,6 → 220,3 ms), do thêm bước retrieval (~20 ms) và prompt dài hơn.
- **Chất lượng:** accuracy tăng từ 4,3% lên 91,3%, rồi lên 100% sau khi sửa KB.
- **Cost / câu đúng:** v2 tốn 0,00003607 USD so với 0,00040575 USD của v1, tức **rẻ hơn khoảng 11 lần**, vì gần như toàn bộ tiền của v1 trả cho câu trả lời sai. Nếu chỉ nhìn "cost / câu", v1 trông rẻ hơn và ta sẽ kết luận sai.
- Bản sửa KB chỉ tốn thêm 7,7 token/câu và 9,8 ms p95, nhưng cost / câu đúng còn giảm thêm (0,00003544 USD).

**Lưu ý:** p95 khi eval (23 câu) **không dùng để kết luận về latency**. Ở lần chạy quality gate, v1 có p95 = 1501,9 ms chỉ vì 2 trong 23 câu rơi vào nhóm request chậm. Mẫu quá nhỏ, latency phải đo bằng load test ở mục 2.

---

## 4. Observability stack (production)

### 4.1 Screenshot

- [ ] `screenshots/grafana-dashboard.png` — dashboard khi đang có tải (Golden Signals)
- [ ] `screenshots/jaeger-slow-trace.png` — trace chậm, thấy span `chat mock-llm-small` chiếm gần hết thời gian
- [ ] `screenshots/jaeger-error-trace.png` — trace lỗi (`error=true`) có event `exception`
- [ ] `screenshots/prometheus-alert-firing.png` — trang Alerts, ≥ 2 alert cùng **firing**

### Exercise 7.4 — trả lời

1. p95 ⟪ … ⟫ ms, avg ⟪ … ⟫ ms. Khoảng cách lớn (p95/p99 ≫ avg) = có tail latency: phần lớn request nhanh nhưng một nhóm nhỏ rất chậm (do LLM upstream).
2. Panel "Requests/s theo instance": ⟪ hai đường gần bằng nhau ⟫ → Nginx round-robin chia đều.
3. Input tokens/s > output tokens/s vì input gồm system prompt + context retrieval + câu hỏi (dài), còn output chỉ là câu trả lời ngắn.
4. `curl http://localhost:8080/metrics` → **404**: Nginx chặn `/metrics` ra ngoài (metrics lộ thông tin nội bộ: route, version, cost…); Prometheus scrape thẳng từng agent trong network nội bộ.

### 4.2 Thí nghiệm "phá hệ thống" (Locust ~30 user chạy liên tục)

| # | Thay đổi | Alert nào firing | Thời gian từ lúc đổi → firing | Panel nào phản ánh rõ nhất |
|---|---|---|---|---|
| A | `MOCK_ERROR_RATE=0.2` | `AgentHighErrorRate` | ⟪ … ⟫ (lý thuyết ≈ 1 phút `for` + scrape/eval) | Error rate (đỏ), Requests/s theo status (5xx tăng) |
| B | `MOCK_SLOW_RATE=0.3` | `AgentHighLatencyP95` | ⟪ … ⟫ (≈ 2 phút `for`) | Latency p50/p95/p99 — p95/p99 vọt, avg tăng ít hơn |
| C | `LLM_MODEL=mock-llm-large` | `LLMCostBurnRateHigh` | ⟪ … ⟫ (≈ 2 phút `for`, rate 5m) | Cost USD/giờ (tăng ~16×), LLM p95 tăng |
| D | `docker pause` 1 instance | `AgentInstanceDown` | ⟪ … ⟫ (≈ 30 s `for`) | Instances up giảm; Locust thấy 504, panel Error rate của agent vẫn xanh |
| E | `AGENT_VERSION=v1` | Không có | — | Retrieval hit ratio về 0, tokens/s giảm, bảng version đổi |

**Thí nghiệm E không làm alert nào firing — phát hiện bằng cách nào?** Lỗi chất lượng không làm metric hạ tầng đỏ. Cần: (1) eval golden dataset làm quality gate trong CI/CD trước deploy (đã có); (2) online eval: chấm mẫu ngẫu nhiên traffic thật bằng LLM-as-judge, đẩy metric `agent_answer_quality` lên Prometheus và alert khi giảm; (3) metric/alert trên tín hiệu proxy như retrieval hit ratio giảm đột ngột, phản hồi 👎 của người dùng, và alert khi `agent_info{version}` đổi ngoài lịch release.

### 4.3 Debug bằng trace

- `trace_id`: ⟪ … ⟫
- Tổng thời gian: ⟪ … ⟫ ms
- Span chiếm nhiều thời gian nhất: ⟪ `chat mock-llm-small` (… ms, …%) ⟫ — nằm ở LLM upstream, không phải code agent (retrieval chỉ ~20 ms)
- Dòng log tương ứng (`docker compose -p k5-day14-observability logs agent | grep <trace_id>`):

```json
⟪ dán dòng log JSON ⟫
```

---

## 5. Benchmark scaling (production, Locust headless, 100 users, 2 phút)

⟪ dán bảng "5" từ `make_report_tables.py` ⟫

**Giải thích:** ⟪ đối chiếu với số của bạn ⟫ Scale 1 → 3 instance tăng RPS (tải chia cho 3 event loop) và giảm phần latency do xếp hàng, nhưng p95 không giảm được dưới latency của chính LLM (~150–250 ms, tail ~1,7 s). Nếu p95 gần như không đổi thì nút thắt là **LLM upstream** (panel LLM latency), không phải số instance — scale ngang chỉ giúp khi bottleneck là CPU/concurrency của agent.

---

## 6. Kết luận

- 3 điều học được:
  1. Average latency đánh lừa; SLO phải đặt theo p95/p99 và đo bằng load test đủ lớn, không phải bằng 23 câu eval.
  2. Hạ tầng xanh ≠ câu trả lời đúng: cần eval golden dataset + quality gate (exit code) trong CI, so sánh bằng cost / câu đúng.
  3. Metrics → traces → logs nối với nhau qua `trace_id`: dashboard báo có vấn đề, Jaeger chỉ ra span chậm, log cho chi tiết; metric chỉ thấy những gì chính service đó thấy (504 ở Nginx không hiện ở agent).
- Nếu lên production thật, thêm: metric + alert ở tầng LB (5xx/504 của Nginx) và synthetic check từ bên ngoài; alert tỉ lệ 429/402 (rate limit, hết budget); alert retrieval hit ratio giảm; online quality score; alert error budget burn rate nhiều cửa sổ (1h/6h) thay cho ngưỡng cố định; Alertmanager gửi Slack/PagerDuty.