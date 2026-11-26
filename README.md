# SLE Project 1 — Threat Detection, Monitoring and Prevention

A scalable service-oriented architecture (SOA), instrumented with **Prometheus**
(performance/availability) and the **Wazuh SIEM** (security events), exercised against four
network threats with detection, correlation (FCAPS fault workflow) and action-response.
Everything runs on an isolated Incus lab inside one Debian VM (`ssh -p 2222 sle@127.0.0.1`,
bridge `10.255.255.0/24`).

> Full write-up: [`report/REPORT.md`](report/REPORT.md).

## Architecture (the managed system)
Temperature SOA in `soa-container`: registry + 2× storage + ingestion + analytics + sensor,
with hierarchical location-aware naming (`country.region.dc.rack.node/kind#instance`),
registry discovery and round-robin load balancing. Monitored by `prometheus-container` (health
exporter + Incus per-container metrics) and `wazuh-container` (agents on the targets).

| Container | IP | Role |
|---|---|---|
| wazuh-container | 10.255.255.4 | SIEM manager |
| prometheus-container | 10.255.255.153 | Prometheus + alert rules |
| soa-container | 10.255.255.204 | SOA services + exporter (DoS target) |
| apache-container | 10.255.255.241 | web victim (DoS/web + C2 victim); Wazuh agent 001 |
| mail-container | 10.255.255.206 | Postfix/Dovecot/SpamAssassin; Wazuh agent 002 |
| metasploit-container | 10.255.255.81 | Kali C2 (transient) |
| load-client-a/b | 10.255.255.211 / .212 | ApacheBench load generators (transient) |
| mitm-interceptor | 10.255.255.227 (+ mitm-net 10.66.0.2) | on-path interceptor, MitM bonus (transient) |

## Threats
| # | Threat | Folder | Detection | Response |
|---|---|---|---|---|
| 1 | Massive DoS / DDoS | [`threats/01-ddos`](threats/01-ddos) | Prometheus QoS + Wazuh 100110 | rate-limit + firewall-drop |
| 2 | Junk email / Spam | [`threats/02-spam`](threats/02-spam) | SpamAssassin + Wazuh 100201-3 | quarantine + SMTP rate limit |
| 3 | Botnet / C2 (APT) | [`threats/03-c2`](threats/03-c2) | Wazuh FIM 100301 + C2 100300 | kill shell + block egress |
| 4 | MitM (bonus) | [`threats/04-mitm`](threats/04-mitm) | extra hop / cert change | TLS + cert pinning |

## Repository layout
- `architecture/` — SOA services + health exporter; `ratelimit.py` (per-identity token bucket).
- `monitoring/` — `prometheus.yml`, `soa_alerts.yml`, `remediate.sh` (rate-limit tool),
  `alertmanager.yml` + `install-alertmanager.sh` (root-cause alert correlation).
- `siem/` — consolidated Wazuh decoders/rules + active-response + `install_siem.sh`.
- `threats/00-attack-surface/` — post-foothold probe that **measures** the attack surface.
- `threats/NN-*/` — per-threat setup, PoC scripts, `README.md`, `evidence/`.
- `tools/` — measurement/rigor drivers: `correlation-demo.sh`, `scalability-sweep.sh`,
  `identity-vs-ip-demo.sh`, `load_sensors.py`, `make-figures.py`.
- `lab/` — `network.sh`, `genesis.sh` (rebuild core), `control.sh` (RAM-aware up/down).
- `evidence/` — raw captures backing every headline number in the report.
- `report/` — `REPORT.md` (full write-up), `report.tex`/`report.pdf` (compiled report), figures.
- `REPRODUCE.md` — step-by-step end-to-end reproduction guide.

## Running it
> **Memory:** the VM has 8 GB, no swap; Wazuh's indexer alone ≈ 2.3 GB. Keep a small core
> and bring each threat's extra containers up only for its PoC. The earlier whole-stack OOM
> that froze the VM is why `control.sh` sequences things.

```bash
# core up + health check
bash lab/genesis.sh                 # rebuild/refresh core (idempotent)
bash lab/control.sh status
# per threat (see each threat README for the PoC commands)
bash lab/control.sh ddos up   # ... run threats/01-ddos ...   ; bash lab/control.sh ddos down
bash lab/control.sh spam up   # ... run threats/02-spam ...   ; bash lab/control.sh spam down
bash lab/control.sh c2   up   # ... run threats/03-c2  ...   ; bash lab/control.sh c2   down
# SIEM content (fresh manager):
bash siem/install_siem.sh
# root-cause alert correlation (Alertmanager inhibition):
bash monitoring/install-alertmanager.sh
# measurement/rigor tools (produce evidence/ + report figures):
bash tools/correlation-demo.sh        # cascade -> root cause
bash tools/scalability-sweep.sh       # throughput/latency at N = 10/50/100
bash tools/identity-vs-ip-demo.sh     # per-IP vs per-identity rate limiting
```

> Full end-to-end reproduction (prerequisites, every command, evidence paths):
> [`REPRODUCE.md`](REPRODUCE.md).

Access the dashboards from your host by forwarding over SSH:
```bash
ssh -p 2222 -L 9090:10.255.255.153:9090 -L 8443:10.255.255.4:443 sle@127.0.0.1
#   Prometheus http://localhost:9090   ·   Wazuh https://localhost:8443
```

## Safety
Lab-only. DoS workloads are bounded and target only our own containers. C2 (Metasploit)
traffic never leaves the VM — `payload.sh` refuses any non-`10.255.255.x` LHOST. MitM uses an
isolated subnet, no ARP spoofing, no third-party traffic.
