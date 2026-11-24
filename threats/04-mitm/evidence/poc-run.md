# Threat 4 (MitM / route hijacking, bonus) — PoC evidence

Isolated topology (second subnet, no ARP spoofing, no external traffic):

```
mitm-client (10.66.0.10, mitm-net only)
     └─ default route via 10.66.0.2 ─▶ mitm-interceptor (eth1 10.66.0.2 | eth0 10.255.255.227)
                                              └─ forwards (MASQUERADE) ─▶ apache-container 10.255.255.241
```
The interceptor is the client's **only** gateway to the target — a hijacked route. Date 2026-11-24.

## Interception works (confidentiality loss)
Client fetch through the route succeeds (`HTTP 200`), and the interceptor captured the full
plaintext in transit (`/root/cap3.pcap`, 12 packets):

```
IP mitm-interceptor > apache-container.http: ... GET / HTTP/1.1
IP apache-container.http > mitm-interceptor: ... HTTP/1.1 200 OK
Server: Apache/2.4.52 (Ubuntu)
<title>Apache2 Ubuntu Default Page: It works</title>
```
An on-path attacker reads (and could modify) all unencrypted traffic.

## Detection (from the client)
- **Extra hop** — `traceroute 10.255.255.241` shows hop 1 = `10.66.0.2` (the interceptor).
  A direct same-subnet destination has no intermediate hop.
- **TTL decrement** — reply `ttl=63` instead of the Linux default `64`: exactly one extra
  forwarding hop. An unexpected decrement is the route-hijack signal.

## Mitigation
- **TLS everywhere** — with HTTPS the interceptor can forward but cannot read the content;
  to read it, it must present its own certificate → the client's **cert pinning / HSTS**
  check fails and the MitM is detected and blocked.
- **Routing hardening** — static/authenticated routes, ignore ICMP redirects
  (`net.ipv4.conf.*.accept_redirects=0`), so the route cannot be silently hijacked.

## Post-mortem / limitations
- This models a *route-level* MitM (the attacker is the gateway). Active content
  modification would use a transparent proxy (e.g. mitmproxy); mitmproxy is not packaged on
  Debian trixie, so read-interception is shown via packet capture — sufficient to prove the
  confidentiality break. Modification capability is identical in principle once on-path.
- Detection here is client-side (hop/TTL). At scale, the network fabric should detect
  topology changes centrally (e.g. unexpected new gateway / BGP or ARP monitoring).
