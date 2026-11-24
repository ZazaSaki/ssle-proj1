# Threat 1 — Massive Denial of Service (DoS / DDoS)

**Syllabus:** Massive denial-of-service disruptions. **Guide:** Practical Guide 5.

## Description & relevance
A DoS exhausts a finite resource (CPU, workers, connections) to deny availability to
legitimate users; a DDoS spreads the load over many sources. Our managed system is the
SOA temperature pipeline; its analytics `/anomalies` endpoint is expensive (reads up to
1000 rows and computes statistics on every call), so it is the natural pressure point —
the "attack surface A2" in the architecture's Attack-Defense Tree.

## How it is exploited
Two lab containers (`load-client-a/b`) run ApacheBench against
`http://10.255.255.204:5003/anomalies`, time-boxed and bounded. Two simultaneous
sources emulate a small botnet.

## Monitoring (metrics & rules)
Prometheus group `soa_qos` in `monitoring/soa_alerts.yml`:
- `DoS_RequestFlood` — `rate(service_requests_total) > 10` (baseline < 0.2).
- `QoSDegraded_AnalyticsLatency` — `/health` probe latency > 0.05 s (baseline ~0.005 s).
- `DoS_TargetCPUSaturated` — `incus_cpu_seconds_total` for soa-container > 0.8 core.
- Alert window `for: 30s` (degradation must be sustained → tolerates flash-crowd blips);
  Prometheus auto-resolves ~30–60 s after recovery.

## Action-response
`monitoring/remediate.sh rate-limit` on the target — iptables hashlimit, > 10 new
conn/s per source IP dropped (burst 30). Protects CPU/latency and leaves the
legitimate low-rate client untouched. Does **not** stop a distributed attack (each IP
still gets its quota) → see Threat 3.

## Run it
```bash
# on the VM
bash lab/control.sh ddos up            # start load clients (or threats/01-ddos/setup.sh first time)
bash threats/01-ddos/run.sh baseline   # 1 client, 40 req
bash threats/01-ddos/run.sh attack     # 2 clients, time-boxed 60 s, c=10 each
# inspect alerts: http://localhost:9090/alerts  (ssh -L 9090:10.255.255.153:9090)
incus exec soa-container -- bash /root/remediate.sh rate-limit   # mitigate
bash threats/01-ddos/run.sh attack                               # re-test
incus exec soa-container -- bash /root/remediate.sh reset
bash lab/control.sh ddos down
```

Parameters (env vars for `run.sh`): `TARGET_URL`, `DUR` (attack seconds), `CONC`
(concurrency per client), `BASE_N` (baseline request count).

Evidence & post-mortem: [`evidence/poc-run.md`](evidence/poc-run.md).
