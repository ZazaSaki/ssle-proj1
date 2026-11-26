# Attack surface — measured, not asserted

Instead of listing the attack surface on paper, a throwaway **probe** sends one real
request per candidate exposure from the realistic adversary position and records whether
each one is **CONFIRMED** or **BLOCKED**, with the evidence line that proves it.

**Threat model.** The adversary has already reached the service network (a crossed
perimeter, or a compromised neighbouring workload) but holds **no credentials**. This is
why the probe runs *from inside* `soa-container`: the registry and storage replicas are
localhost-bound and only become reachable *after* a foothold.

## Run

```bash
# from the VM, with the CORE lab up (lab/genesis.sh)
incus file push -q projeto1/threats/00-attack-surface/probe.sh soa-container/opt/soa/probe.sh
incus exec soa-container -- bash /opt/soa/probe.sh | tee evidence/attack-surface-$(date -u +%Y%m%d-%H%M%S).txt
```

The probe is read-mostly and self-restoring: the one destructive check (`DELETE /unregister`)
immediately re-registers what it evicted, and the service self-heals on its next heartbeat
regardless.

## What it checks

| # | Exposure | Request | Typical result |
|---|----------|---------|----------------|
| 1 | Discovery poisoning | `POST /register` a decoy, then `GET /discover` | CONFIRMED — clients steered to the attacker URL |
| 2 | One-request DoS | `DELETE /unregister` a live instance | CONFIRMED — a single request evicts it |
| 3 | Forged data | `POST /ingest` a plausible reading from a ghost device | CONFIRMED — accepted (shape/range *is* validated; identity is **not**) |
| 4 | Topology leak | `GET /services` | CONFIRMED — hands out the labelled rack/node map |
| 5 | Open monitoring plane | unauth `GET` to Prometheus / Wazuh APIs | Prometheus CONFIRMED open; Wazuh API auth-gated |
| 6 | Plaintext transport | `http` vs `https` to a service | CONFIRMED — plain HTTP, no TLS (see Threat D) |

## Why it matters

Each confirmed exposure maps to a node in the consolidated attack–defense tree and to a
ranked residual-risk item in `report/REPORT-additions.md`. The measured surface is the honest
baseline the four threat experiments then exploit, detect and (where a control exists) mitigate.
The controls that **held** are recorded too: lab isolation (no egress), unprivileged hardened
containers, and the localhost-binding that keeps the registry and storage replicas off the
pre-foothold surface.
