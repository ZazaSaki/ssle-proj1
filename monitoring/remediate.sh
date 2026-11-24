#!/bin/bash
# Guide 3, step 7: remediation / prevention for soa-container.
# Run INSIDE soa-container (needs iptables):
#   incus file push remediate.sh soa-container/root/ && incus exec soa-container -- bash /root/remediate.sh <cmd>
#
#   rate-limit         per-source-IP rate limit on the exposed ports (5001 ingestion, 5003 analytics)
#   block <ip>         drop everything from one IP (blocklist)
#   unblock <ip>
#   status             show current rules and packet counters
#   reset              remove everything this script added
set -e
CHAIN=SOA-GUARD
PORTS=5001,5003
RATE=${RATE:-10/second}   # sustained requests per source IP (normal traffic is < 1/s)
BURST=${BURST:-30}

command -v iptables >/dev/null || { apt-get update -qq && apt-get install -y -qq iptables >/dev/null; }

ensure_chain() {
    iptables -N $CHAIN 2>/dev/null || true
    iptables -C INPUT -p tcp -m multiport --dports $PORTS -j $CHAIN 2>/dev/null \
        || iptables -I INPUT -p tcp -m multiport --dports $PORTS -j $CHAIN
}

case "$1" in
  rate-limit)
    ensure_chain
    iptables -D $CHAIN -p tcp --syn -m hashlimit --hashlimit-name soa --hashlimit-mode srcip \
        --hashlimit-above $RATE --hashlimit-burst $BURST -j DROP 2>/dev/null || true
    # Only new connections are counted, so established keep-alive sessions are not cut
    iptables -A $CHAIN -p tcp --syn -m hashlimit --hashlimit-name soa --hashlimit-mode srcip \
        --hashlimit-above $RATE --hashlimit-burst $BURST -j DROP
    echo "rate limit: > $RATE new connections per source IP (burst $BURST) are dropped"
    ;;
  block)
    ensure_chain
    iptables -I $CHAIN -s "${2:?ip}" -j DROP
    echo "blocked $2"
    ;;
  unblock)
    iptables -D $CHAIN -s "${2:?ip}" -j DROP
    echo "unblocked $2"
    ;;
  status)
    iptables -L $CHAIN -n -v 2>/dev/null || echo "no $CHAIN chain"
    ;;
  reset)
    iptables -D INPUT -p tcp -m multiport --dports $PORTS -j $CHAIN 2>/dev/null || true
    iptables -F $CHAIN 2>/dev/null || true
    iptables -X $CHAIN 2>/dev/null || true
    echo "removed $CHAIN"
    ;;
  *)
    sed -n '2,13p' "$0"; exit 1
    ;;
esac
