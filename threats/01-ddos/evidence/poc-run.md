# Threat 1 (DDoS) — PoC evidence

Target: SOA **analytics `/anomalies`** on `soa-container` (10.255.255.204:5003) — an
expensive endpoint (reads up to 1000 rows + computes stats). Two lab load clients
(`load-client-a` 10.255.255.82, `load-client-b` 10.255.255.76) with ApacheBench.
Date: 2026-11-24. Workload time-boxed, lab bridge only.

## Worksheet

| scenario | clients | concurrency | duration | throughput (req/s) | p50 (ms) | p95 (ms) | non-2xx | target CPU (cores) | /health latency | alert |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 1 | 1 | 40 req | 34.7 | 29 | 33 | 0 | 0.04 | 5 ms | none |
| attack (per client) | 2 | 10 each (20 total) | 60 s | 30.4 / 30.7 | 290 | 488 | 0 | 0.87 → 1.64 | 202 ms | **fired** |

Aggregate attack rate reaching analytics ≈ 61 req/s; it propagated down to
`storage-service` (~65 req/s) because every `/anomalies` call fans out to storage.

## Metric snapshots (from Prometheus)

```
baseline [pre]   analytics req/s=0.31  health_lat=0.003s  soa_cpu=0.044 cores
attack   [mid]   analytics req/s=22.7  health_lat=0.202s  soa_cpu=0.874 cores
attack   [post]  analytics req/s=61.5  health_lat=0.067s  soa_cpu=1.641 cores
```

## Alerts that fired (Prometheus, group `soa_qos`)

- `DoS_RequestFlood` — analytics-service flooded at 65 req/s (baseline < 0.2)
- `DoS_RequestFlood` — storage-service flooded at 65 req/s  ← attack propagation
- `DoS_TargetCPUSaturated` — soa-container CPU saturated at 1.64 cores
- (`QoSDegraded_AnalyticsLatency` crossed its threshold at mid-attack: /health 0.202 s > 0.05 s)
- Legacy rules `HighRequestRate`, `ContainerHighCPU` also fired (confirming correlation).

**Recovery:** after the time-boxed run ended, request rate returned to 0.31 req/s and all
`threat=dos` alerts auto-cleared within one evaluation window (`for: 30s`).

## Correlation (FCAPS: Detect → Isolate → Correlate → source)

1. Alert: analytics QoS degraded + request flood.
2. Victim: `analytics-service` (and, downstream, `storage-service`).
3. Source: `soa-container` ingress bytes + CPU rose in the same window; ApacheBench
   `ab` ran from `load-client-a/b` (their egress bytes rose together) → two sources
   acting at once = the (emulated) botnet.

## Note on "failed requests"

ApacheBench reported ~1000 "failed" requests with **non-2xx = 0**. These are *length*
mismatches: `/anomalies` returns a JSON body whose size changes as the anomaly set
changes, so `ab` counts them as "failed" by length. They are **not** availability
failures. This is exactly why *throughput alone does not demonstrate loss of
availability* — latency (p95 29→488 ms) and resource saturation are the real evidence.

---

## Mitigation PoC (per-IP rate limit)

Applied `monitoring/remediate.sh rate-limit` on `soa-container` (hashlimit: drop
> 10 new conn/s per source IP, burst 30, on ports 5001/5003). Same attack re-run:

| metric | no mitigation | with rate limit |
|---|---|---|
| attacker throughput (per client) | 30 req/s | **10 req/s** (capped) |
| SOA CPU (mid) | 0.87 cores | **0.25 cores** |
| /health latency (mid) | 0.202 s | **0.003 s** (baseline) |
| SYN packets dropped | — | **958** |
| legitimate client | degraded | **served in 17 ms** |

So the control **protects the service** (CPU and latency stay at baseline, the
legitimate low-rate client is unaffected) by capping each source IP.

**What it does NOT stop:** a *distributed* attack — each of N source IPs still gets
10 req/s through, so 1000 bots = 10 000 req/s. This is the limitation that motivates
Threat 3 (botnet/C2): the real defence against distributed sources is upstream
filtering / reputation blocklists / autoscaling, not a single per-IP limit.
