#!/bin/bash
# Root-cause correlation demo (SLE Project 1).
#
# A fault in a service-oriented architecture produces a CASCADE of alerts: the one
# broken dependency plus every downstream symptom. This injects one fault — a storage
# TIER outage (both SQLite replicas) — and shows that Alertmanager's inhibition rules
# (monitoring/alertmanager.yml) suppress the downstream SYMPTOM alerts while their
# CAUSE is still firing, so the operator is shown the fault to fix, not its consequences.
#
#   Run on the VM:  bash projeto1/tools/correlation-demo.sh
set -uo pipefail
P=http://10.255.255.153:9090        # Prometheus
A=http://10.255.255.153:9093        # Alertmanager
WAIT=${WAIT:-85}                    # seconds to let for:15-30s rules fire + evaluate

fire_json() { curl -s "$P/api/v1/alerts" | python3 -c 'import sys,json;print(json.dumps([a for a in json.load(sys.stdin)["data"]["alerts"] if a["state"]=="firing"]))'; }
am_json()   { curl -s "$A/api/v2/alerts"; }

echo "=========================================================================="
echo " ROOT-CAUSE CORRELATION DEMO   date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " fault injected: storage TIER outage (stop soa-storage-a + soa-storage-b)"
echo "=========================================================================="

echo "[0] baseline firing alerts: $(fire_json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')"

echo "[1] INJECT fault ..."
incus exec soa-container -- systemctl stop soa-storage-a soa-storage-b
echo "    waiting ${WAIT}s for the cascade to form ..."
sleep "$WAIT"

RAW=$(fire_json)
AM=$(am_json)

echo
echo "--- Prometheus: the RAW cascade (every rule that is firing) ---"
echo "$RAW" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(f"  {len(d)} alerts firing:")
for a in d:
    l=a["labels"]; who=l.get("service_id",l.get("service",""))
    print("    - %-28s %-9s %s" % (l["alertname"], l.get("severity",""), who))
'

echo
echo "--- Alertmanager: what the OPERATOR actually sees (after inhibition) ---"
echo "$AM" | python3 -c '
import sys,json
al=json.load(sys.stdin)
act=[a for a in al if a["status"]["state"]=="active"]
sup=[a for a in al if a["status"]["state"]=="suppressed"]
def names(xs):
    return [a["labels"]["alertname"]+" ("+a["labels"].get("service_id",a["labels"].get("service",""))+")" for a in xs]
print(f"  SHOWN  (root causes)   : {len(act)}")
for n in names(act): print(f"    * {n}")
print(f"  INHIBITED (symptoms)   : {len(sup)}")
for n in names(sup): print(f"    - {n}")
tot=len(act)+len(sup)
if tot:
    print()
    print(f"  => {tot} alerts fired; inhibition collapsed them to {len(act)} cause(s) the operator must fix,")
    print(f"     hiding {len(sup)} downstream symptom(s). Noise reduction: {100*len(sup)//tot}%.")
'

echo
echo "[2] RESTORE ..."
incus exec soa-container -- systemctl start soa-storage-a soa-storage-b
for _ in $(seq 1 12); do
  n=$(fire_json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')
  [ "$n" = "0" ] && break; sleep 5
done
echo "    restored; firing alerts cleared to: $n"
echo "=========================================================================="
