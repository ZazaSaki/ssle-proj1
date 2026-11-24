#!/bin/bash
# RAM-aware lab control. Run ON THE VM.
#
# The VM has 8 GB and no swap; Wazuh's indexer alone ~2.3 GB. So we keep a small
# always-on CORE and bring each threat's extra containers up only for its PoC.
#
#   ./control.sh core  up|down
#   ./control.sh ddos  up|down     # load-client-a, load-client-b
#   ./control.sh spam  up|down     # mail-container
#   ./control.sh c2    up|down     # metasploit-container, victim-container
#   ./control.sh mitm  up|down     # mitm-client, mitm-interceptor
#   ./control.sh status
set -euo pipefail

CORE="wazuh-container prometheus-container soa-container apache-container"
declare -A SET=(
  [ddos]="load-client-a load-client-b"
  [spam]="mail-container"
  [c2]="metasploit-container victim-container"
  [mitm]="mitm-client mitm-interceptor"
)
# Containers NOT part of this project (k3s, docker, …) are left stopped.

act() {  # act start|stop <names...>
  local verb=$1; shift
  for c in "$@"; do
    incus info "$c" >/dev/null 2>&1 || { echo "  $c absent (run genesis.sh / the threat setup)"; continue; }
    local st; st=$(incus list "$c" -c s -f csv)
    if [ "$verb" = start ] && [ "$st" != RUNNING ]; then incus start "$c"; echo "  started $c"
    elif [ "$verb" = stop ] && [ "$st" = RUNNING ]; then incus stop "$c"; echo "  stopped $c"
    else echo "  $c already ${st,,}"; fi
  done
}

grp=${1:-status}; op=${2:-}
case "$grp" in
  core)
    case "$op" in up) act start $CORE ;; down) act stop $CORE ;; *) echo "usage: $0 core up|down"; exit 1 ;; esac ;;
  ddos|spam|c2|mitm)
    case "$op" in up) act start ${SET[$grp]} ;; down) act stop ${SET[$grp]} ;; *) echo "usage: $0 $grp up|down"; exit 1 ;; esac ;;
  status)
    echo "== containers"; incus list -c ns4 -f csv
    echo "== memory (MB)"; free -m | awk '/Mem/{print "  total",$2,"used",$3,"free",$4,"avail",$7}' ;;
  *) echo "usage: $0 core|ddos|spam|c2|mitm up|down  |  status"; exit 1 ;;
esac
