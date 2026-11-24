#!/bin/bash
# Threat 4 (MitM) — run FROM the client to (a) show traffic is intercepted and
# (b) detect the on-path interceptor. Run INSIDE mitm-client.
APACHE=${APACHE:-10.255.255.241}
command -v curl >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq curl traceroute iputils-ping >/dev/null; }

echo "== fetch target through the (hijacked) route"
curl -s -D - "http://$APACHE/" -o /dev/null | grep -iE "X-Intercepted-By|HTTP/" || echo "  (no interception header)"

echo "== DETECTION 1: extra hop on the path (route hijack signal)"
traceroute -n -m 5 "$APACHE" 2>/dev/null | sed -n '1,4p'

echo "== DETECTION 2: TTL of replies (decremented by the extra forwarding hop)"
ping -c1 "$APACHE" 2>/dev/null | grep -oE "ttl=[0-9]+" | head -1
echo "  (a direct same-subnet host would show the OS default TTL, e.g. 64; a forwarded"
echo "   path shows 63 — one decrement per hop. An unexpected decrement = an extra hop.)"
