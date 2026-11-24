#!/bin/bash
# Threat 1 (DDoS) — create two bounded load-generator containers. Run ON THE VM.
# Safety: lab only, bounded workload, targets ONLY our own 10.255.255.0/24 containers.
set -euo pipefail
IMG=images:debian/trixie

for c in load-client-a load-client-b; do
  if incus info "$c" >/dev/null 2>&1; then incus start "$c" 2>/dev/null || true; echo "$c exists"
  else echo "launching $c"; incus launch "$IMG" "$c"; sleep 6; fi
  incus exec "$c" -- bash -c 'command -v ab >/dev/null && command -v curl >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq apache2-utils curl >/dev/null; }' </dev/null
  echo "  $c: ab=$(incus exec "$c" -- bash -lc 'command -v ab') curl=$(incus exec "$c" -- bash -lc 'command -v curl')"
done
echo "clients ready:"; incus list load-client -c ns4 -f csv
