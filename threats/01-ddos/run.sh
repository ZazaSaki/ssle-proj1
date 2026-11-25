#!/bin/bash
# Threat 1 (DDoS) PoC driver. Run ON THE VM after setup.sh.
# Bounded, lab-only. Target = SOA analytics /anomalies (expensive: reads up to 1000
# rows + stats) on soa-container; Apache is an optional fast-page control.
#
#   ./run.sh baseline        one client, short, low concurrency
#   ./run.sh attack          both clients, time-boxed sustained, higher concurrency
#   ./run.sh sample <secs>   just sample Prometheus/CPU for N seconds (no load)
#
# Evidence (ab output + sampled metrics) is printed; redirect to evidence/.
set -euo pipefail
PROM=http://10.255.255.153:9090/api/v1
TARGET_URL=${TARGET_URL:-http://10.255.255.204:5003/anomalies}
DUR=${DUR:-60}            # attack duration (s) — time-boxed
CONC=${CONC:-10}          # concurrency per client
BASE_N=${BASE_N:-40}      # baseline request count (guide-bounded)

q(){ curl -s "$PROM/query" --data-urlencode "query=$1" | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(round(float(r[0]["value"][1]),3) if r else "n/a")'; }

snapshot(){ # label
  echo "  [$1] analytics req/s=$(q 'sum(rate(service_requests_total{service="analytics-service"}[1m]))')" \
       "health_lat_s=$(q 'max(service_health_latency_seconds{service="analytics-service"})')" \
       "avg_lat_s=$(q 'max(service_avg_latency_seconds{service="analytics-service"})')" \
       "soa_cpu_cores=$(q 'sum(rate(incus_cpu_seconds_total{name="soa-container",mode=~"user|system"}[1m]))')"
}

ab_on(){ # ab_on <container> <args...>  -> prints parsed worksheet line
  local c=$1; shift
  incus exec "$c" -- ab "$@" "$TARGET_URL" </dev/null 2>/dev/null | awk '
    /Requests per second/{rps=$4}
    /Complete requests/{comp=$3}
    /Failed requests/{fail=$3}
    /Non-2xx/{non2xx=$3}
    /^Total:/{median=$5} # mean section; we also grab p95 below
    /50%/{p50=$2} /95%/{p95=$2}
    END{printf "    rps=%s complete=%s failed=%s non2xx=%s p50=%sms p95=%sms\n", rps, comp, fail, (non2xx==""?0:non2xx), p50, p95}'
}

case "${1:-}" in
  baseline)
    echo "BASELINE  target=$TARGET_URL  n=$BASE_N c=1"
    snapshot pre
    echo "  load-client-a:"; ab_on load-client-a -n "$BASE_N" -c 1 -s 5
    snapshot post ;;
  attack)
    echo "ATTACK  target=$TARGET_URL  2 clients x (-t ${DUR}s -c ${CONC})  [time-boxed, lab-only]"
    snapshot pre
    # start both clients together, sample mid-run
    ab_on load-client-a -t "$DUR" -c "$CONC" -s 30 > /tmp/ab_a.txt &
    ab_on load-client-b -t "$DUR" -c "$CONC" -s 30 > /tmp/ab_b.txt &
    sleep $((DUR/2)); snapshot mid
    wait
    echo "  load-client-a:"; cat /tmp/ab_a.txt
    echo "  load-client-b:"; cat /tmp/ab_b.txt
    snapshot post
    echo "  (let alerts settle ~30s, then check evidence.sh)" ;;
  sample)
    for i in $(seq 1 "${2:-6}"); do snapshot "t$i"; sleep 5; done ;;
  *) echo "usage: $0 baseline|attack|sample [secs]"; exit 1 ;;
esac
