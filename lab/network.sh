#!/bin/bash
# Idempotent: ensure the lab network exists and core containers keep fixed IPs.
# Run ON THE VM (not inside a container).
#
#   incus-default : 10.255.255.0/24, ipv4.nat, no ipv6  (built in guide 2)
#
# Fixed IPs so the Prometheus/Wazuh/agent configs stay valid across reboots.
set -euo pipefail

NET=incus-default
declare -A IP=(
  [wazuh-container]=10.255.255.4
  [prometheus-container]=10.255.255.153
  [soa-container]=10.255.255.204
  [apache-container]=10.255.255.241
)

if ! incus network show "$NET" >/dev/null 2>&1; then
  echo "creating $NET"
  incus network create "$NET" ipv4.address=10.255.255.1/24 ipv4.nat=true ipv6.address=none
fi

pin() {  # pin <container> <ip>  (only if the container exists)
  local c=$1 ip=$2
  incus info "$c" >/dev/null 2>&1 || { echo "skip $c (absent)"; return; }
  local cur
  cur=$(incus config device get "$c" eth0 ipv4.address 2>/dev/null || true)
  if [ "$cur" = "$ip" ]; then echo "$c already $ip"; return; fi
  incus config device override "$c" eth0 ipv4.address="$ip" 2>/dev/null \
    || incus config device set "$c" eth0 ipv4.address="$ip"
  echo "$c -> $ip (restart to apply if running)"
}

for c in "${!IP[@]}"; do pin "$c" "${IP[$c]}"; done
echo "done. Current addresses:"
incus list -c ns4 -f csv
