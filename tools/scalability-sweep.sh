#!/bin/bash
# Scalability sweep (SLE Project 1).
# Emulates ONE node hosting N sensors (N distinct identities, one source IP) and
# measures the ingestion pipeline at N = 10 / 50 / 100: achieved throughput, client
# p50/p95 latency, and the soa-container CPU used (counter delta over the run).
#
#   Run on the VM:  bash projeto1/tools/scalability-sweep.sh [out.csv]
set -uo pipefail
P=http://10.255.255.153:9090
ING=http://10.255.255.204:5001/ingest
CLIENT=load-client-a
DUR=${DUR:-30}
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-/tmp/scalability.csv}

cpu_counter(){ curl -s "$P/api/v1/query?query=sum(incus_cpu_seconds_total%7Bname=%22soa-container%22,mode=~%22user%7Csystem%22%7D)" \
  | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(float(r[0]["value"][1]) if r else 0.0)'; }
jget(){ python3 -c "import sys,json;print(json.load(sys.stdin)[\"$1\"])"; }

echo "=== bringing up $CLIENT ==="
incus start $CLIENT 2>/dev/null || true; sleep 4
incus exec $CLIENT -- bash -c 'command -v python3 >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq python3 >/dev/null 2>&1; }' </dev/null
incus file push -q "$HERE"/tools/load_sensors.py $CLIENT/root/load_sensors.py

echo "sensors,throughput_rps,p50_ms,p95_ms,cpu_cores" > "$OUT"
for N in 10 50 100; do
  echo "--- N=$N sensors for ${DUR}s ---"
  C0=$(cpu_counter); T0=$(date +%s.%N)
  R=$(incus exec $CLIENT -- python3 /root/load_sensors.py --ingest $ING --sensors $N --duration $DUR)
  T1=$(date +%s.%N); sleep 11; C1=$(cpu_counter)   # +11s so the last incus scrape (10s) lands
  EL=$(python3 -c "print($T1-$T0)")
  CPU=$(python3 -c "print(round(($C1-$C0)/$EL,3))")
  TP=$(echo "$R"|jget throughput_rps); P50=$(echo "$R"|jget p50_ms); P95=$(echo "$R"|jget p95_ms)
  echo "$N,$TP,$P50,$P95,$CPU" | tee -a "$OUT"
  sleep 4
done
echo "=== stopping $CLIENT ==="; incus stop $CLIENT 2>/dev/null || true
echo "=== RESULT ($OUT) ==="; cat "$OUT"
