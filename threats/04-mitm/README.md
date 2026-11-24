# Threat 4 — Man-in-the-Middle / Route Hijacking (bonus)

**Syllabus:** Route and signals hijacking. **Guide:** Practical Guide 5 §5.
**Status: implemented and demonstrated** (read-interception + detection).

> Safety: isolated second subnet, **no ARP spoofing**, no campus/third-party traffic. The
> interceptor is the client's legitimate gateway — this models a hijacked route, not L2 poisoning.

## Topology
```
mitm-client (10.66.0.10, mitm-net) --default gw--> mitm-interceptor --> apache (10.255.255.241)
                                     eth1 10.66.0.2 | eth0 10.255.255.227 (MASQUERADE)
```

## How it works
The client's only route to the target goes through the interceptor, which forwards
(`ip_forward` + MASQUERADE) and captures the plaintext in transit — proving an on-path
attacker can read (and could alter) unencrypted traffic.

## Detection
From the client (`detect.sh`): an **extra hop** (traceroute → 10.66.0.2) and a **TTL
decrement** (63 vs 64) reveal the inserted forwarding node.

## Mitigation
TLS + certificate pinning / HSTS (defeats read + makes active MitM visible); routing
hardening (`accept_redirects=0`, authenticated routes).

## Run it
```bash
# on the VM
bash threats/04-mitm/network.sh                                   # build topology
incus exec mitm-interceptor -- bash /root/04-mitm/interceptor_setup.sh   # forward + capture
incus exec mitm-client -- bash /root/04-mitm/detect.sh            # interception + detection
# read captured plaintext:
incus exec mitm-interceptor -- tcpdump -r /root/mitm-capture.pcap -A | grep -i 'GET\|Server:'
# teardown
incus stop mitm-client mitm-interceptor
```

Evidence: [`evidence/poc-run.md`](evidence/poc-run.md).
