# Reproducibility guide

End-to-end steps to rebuild and exercise this project from a clean checkout. Everything runs
on **one Debian VM** that hosts an isolated [Incus](https://linuxcontainers.org/incus/) container
lab on bridge `10.255.255.0/24`. Nothing in here touches the host network or anything outside the
VM.

> **Memory caveat (read first).** The VM has ~8 GB RAM and no swap; Wazuh's indexer alone is
> ≈2.3 GB. Bringing the whole stack up at once has OOM-frozen the VM before — that is why
> `lab/control.sh` sequences containers. Keep a small always-on *core* and bring each threat's
> extra containers up only for its PoC, then take them down.

## 0. Prerequisites (the base VM)

The repo reproduces the **lab inside the VM**; it assumes the VM itself already exists with:

- Debian (trixie) with `systemd`, `python3`, `git`, `curl`.
- **Incus** installed and initialised (`incus admin init` — a default storage pool is enough;
  the lab network is created for you by `lab/network.sh`).
- SSH reachable from the host. In this project it is a VirtualBox VM (10 GB / 8 vCPU) with
  `ssh` forwarded to host port 2222, accessed as `ssh -p 2222 sle@127.0.0.1`.

If you are starting from the course-provided VM, Incus is already present and you can skip
straight to step 1. Building that base VM from scratch is out of scope here (it is the given
substrate), but the only lab-specific requirement is a working Incus with outbound NAT.

## 1. Get the code onto the VM

```bash
ssh -p 2222 sle@127.0.0.1
git clone https://github.com/ZazaSaki/ssle-proj1 projeto1
cd projeto1
```

## 2. Bring up the core + SIEM

```bash
bash lab/genesis.sh            # idempotent: network, SOA + exporter, Prometheus, Wazuh agent
bash lab/control.sh status     # core health check
bash siem/install_siem.sh      # Wazuh decoders/rules + active-response (fresh manager; long)
```

The core (always-on) containers: `wazuh-container` (.4, SIEM), `prometheus-container` (.153,
metrics + alert rules), `soa-container` (.204, the SOA + exporter), `apache-container` (.241,
web victim + Wazuh agent 001).

> `genesis.sh` deliberately does **not** reinstall an already-working Wazuh manager (the install
> is long and memory-heavy). On a truly fresh `wazuh-container`, run `siem/install_siem.sh` once.

## 3. Correlation plane (root-cause alert correlation)

```bash
bash monitoring/install-alertmanager.sh   # Alertmanager on prometheus-container (:9093)
```

This adds the inhibition rules (`monitoring/alertmanager.yml`) that collapse a cascade of alerts
down to its root cause. Standalone and idempotent.

## 4. View the dashboards (from your host)

```bash
ssh -p 2222 -L 9090:10.255.255.153:9090 -L 8443:10.255.255.4:443 sle@127.0.0.1
#   Prometheus  http://localhost:9090      Wazuh  https://localhost:8443
```

## 5. Run the threats (one at a time)

Each threat brings up its own transient containers; take them down afterwards to free RAM. See
each `threats/NN-*/README.md` for the full PoC commands and the evidence it writes.

```bash
# Threat 1 — DoS / DDoS
bash lab/control.sh ddos up
bash threats/01-ddos/run.sh baseline        # then: bash threats/01-ddos/run.sh attack
bash lab/control.sh ddos down

# Threat 2 — Spam
bash lab/control.sh spam up
#   inside mail-container: spam.py gtube | social | volume   (see threats/02-spam/README.md)
bash lab/control.sh spam down

# Threat 3 — Botnet / C2 (APT)
bash lab/control.sh c2 up
#   see threats/03-c2/README.md (payload.sh -> start_handler.sh -> victim_detect.sh)
bash lab/control.sh c2 down

# Threat 4 — MitM (bonus)
#   see threats/04-mitm/README.md (passive read-interception + active on-path modification)
```

## 6. Measurement / rigor tools (the improvement pass)

These produce the numbers and figures in the report. Raw captures land in top-level `evidence/`.

```bash
# Measured attack surface (post-foothold, runs INSIDE soa-container; self-restoring)
incus file push -q threats/00-attack-surface/probe.sh soa-container/opt/soa/probe.sh
incus exec soa-container -- bash /opt/soa/probe.sh \
  | tee evidence/attack-surface-$(date -u +%Y%m%d-%H%M%S).txt

# Root-cause correlation (storage-tier fault -> 4 alerts collapse to 2 causes)
bash tools/correlation-demo.sh          # -> evidence/correlation-*.txt   (needs step 3)

# Scalability sweep (N = 10 / 50 / 100 sensor identities on one node)
bash tools/scalability-sweep.sh         # -> evidence/scalability-*.csv

# Identity-vs-IP (headline: per-IP limiter drops a legit multi-sensor node; per-identity does not)
bash tools/identity-vs-ip-demo.sh       # -> evidence/identity-vs-ip-*.txt
```

The per-identity limiter is **off by default** and gated by an env flag
(`RATELIMIT=identity`, see `architecture/ratelimit.py` + `architecture/ingestion_service.py`);
the demo toggles it via a systemd drop-in and reverts cleanly.

## 7. Figures and report (on the host, not the VM)

```bash
python3 tools/make-figures.py           # evidence/* -> report/figures/fig_*.svg (matplotlib)
cd report && bash build.sh              # SVG -> PDF (Inkscape) + latexmk -> report/report.pdf
```

## 8. Evidence map

Every headline number and figure traces to a capture script and a raw evidence file; the full
mapping is Table 4 ("Evidence map") in `report/report.pdf`, and the raw captures are in
`evidence/` and `threats/*/evidence/`.

## Safety

Lab-only. DoS workloads are bounded and target only our own containers. C2 (Metasploit) traffic
never leaves the VM — `threats/03-c2/payload.sh` refuses any non-`10.255.255.x` LHOST. MitM uses
an isolated subnet, with no ARP spoofing and no third-party traffic. The attack-surface probe
re-registers anything it evicts and leaves the lab intact.
