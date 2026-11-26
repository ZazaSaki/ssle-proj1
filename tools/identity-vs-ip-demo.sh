#!/bin/bash
# Identity-vs-IP demo (SLE Project 1) — the headline scalability->security finding.
#
# One node hosts 50 legitimate sensors (50 identities, ONE source IP).
#   Phase 1: the existing PER-IP limiter (remediate.sh, iptables hashlimit on srcip)
#            is active -> the node's aggregate SYN rate trips it and LEGIT sensors are
#            dropped (a false positive: the control denies the service it protects).
#   Phase 2: a PER-IDENTITY token bucket at ingestion (keyed on device_id) is active
#            instead -> every legitimate identity is served, while a flood that REUSES
#            one identity is shed (HTTP 429).
#
#   Run on the VM:  bash projeto1/tools/identity-vs-ip-demo.sh
set -uo pipefail
ING=http://10.255.255.204:5001/ingest
CLIENT=load-client-a
DUR=${DUR:-15}
HERE=$(cd "$(dirname "$0")/.." && pwd)
jget(){ python3 -c "import sys,json;d=json.load(sys.stdin);print(d[\"$1\"])"; }

echo "=== setup: client up, code + controls pushed ==="
incus start $CLIENT 2>/dev/null || true; sleep 4
incus exec $CLIENT -- bash -c 'command -v python3 >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq python3 >/dev/null 2>&1; }' </dev/null
incus file push -q "$HERE"/tools/load_sensors.py $CLIENT/root/load_sensors.py
# push the (possibly updated) ingestion code + the new limiter module
incus file push -q "$HERE"/architecture/ingestion_service.py "$HERE"/architecture/ratelimit.py soa-container/opt/soa/
incus file push -q "$HERE"/monitoring/remediate.sh soa-container/root/remediate.sh

echo
echo "########## PHASE 1: PER-IP limiter (iptables hashlimit on source IP) ##########"
incus exec soa-container -- systemctl restart soa-ingestion   # ensure RATELIMIT off (baseline)
incus exec soa-container -- bash /root/remediate.sh reset >/dev/null 2>&1 || true
incus exec soa-container -- bash /root/remediate.sh rate-limit
sleep 2
R1=$(incus exec $CLIENT -- python3 /root/load_sensors.py --ingest $ING --sensors 50 --duration $DUR)
DROP=$(incus exec soa-container -- bash -c 'iptables -L SOA-GUARD -n -v 2>/dev/null | awk "/DROP/{s+=\$1} END{print s+0}"')
echo "  result: $R1"
echo "  legit sensors served: $(echo "$R1"|jget legit_served_pct)% ; connection-dropped: $(echo "$R1"|jget legit_failed) ; iptables SYNs dropped: $DROP"
incus exec soa-container -- bash /root/remediate.sh reset >/dev/null 2>&1 || true

echo
echo "########## PHASE 2: PER-IDENTITY token bucket (keyed on device_id) ##########"
incus exec soa-container -- bash -c 'mkdir -p /etc/systemd/system/soa-ingestion.service.d; printf "[Service]\nEnvironment=RATELIMIT=identity\nEnvironment=RL_RATE=5\nEnvironment=RL_BURST=10\n" > /etc/systemd/system/soa-ingestion.service.d/ratelimit.conf; systemctl daemon-reload; systemctl restart soa-ingestion'
sleep 2
# 50 legit sensors (unique identities) + a flood of 3 threads REUSING one identity
R2=$(incus exec $CLIENT -- python3 /root/load_sensors.py --ingest $ING --sensors 50 --duration $DUR \
       --flood-id "pt.aveiro.dc1.rack09.node999/temp-sensor#FLOOD" --flood-threads 3)
echo "  result: $R2"
echo "  legit sensors served: $(echo "$R2"|jget legit_served_pct)% ; flood 200s: $(echo "$R2"|jget flood_ok) ; flood 429s (shed): $(echo "$R2"|jget flood_429)"
# revert ingestion to baseline
incus exec soa-container -- bash -c 'rm -f /etc/systemd/system/soa-ingestion.service.d/ratelimit.conf; rmdir /etc/systemd/system/soa-ingestion.service.d 2>/dev/null; systemctl daemon-reload; systemctl restart soa-ingestion'
echo
echo "=== cleanup ==="; incus stop $CLIENT 2>/dev/null || true
echo "DONE: per-IP throttled the legitimate multi-identity node; per-identity served it and shed the single-identity flood."
