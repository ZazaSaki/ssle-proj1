#!/bin/bash
# Rebuild the CORE lab reproducibly. Run ON THE VM, from a directory that
# contains the project tree (push it with:  scp -r projeto1 sle@vm:/tmp/ ).
#
#   ./genesis.sh            # build/refresh core (SOA + Prometheus + Wazuh agent on apache)
#
# Wazuh server install itself is long and memory-heavy; it is NOT re-run here if
# wazuh-container already has a working manager. Use threats/.. scripts for the
# per-threat containers. This script is idempotent: safe to re-run.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # projeto1/
IMG=images:debian/trixie

say(){ echo -e "\n=== $*"; }

launch(){ # launch <name> [image]
  local c=$1 img=${2:-$IMG}
  if incus info "$c" >/dev/null 2>&1; then echo "$c exists"; incus start "$c" 2>/dev/null || true
  else say "launching $c ($img)"; incus launch "$img" "$c"; sleep 8; fi
}

# ---------- network ----------
say "network"; bash "$HERE/lab/network.sh"

# ---------- SOA + exporter (soa-container) ----------
launch soa-container
incus exec soa-container -- mkdir -p /opt/soa
incus file push -q "$HERE"/architecture/*.py "$HERE"/architecture/dashboard.html soa-container/opt/soa/
incus file push -q "$HERE"/architecture/setup_soa_container.sh soa-container/opt/soa/
incus config device get soa-container eth0 ipv4.address >/dev/null 2>&1 || \
  incus config device override soa-container eth0 ipv4.address=10.255.255.204
incus restart soa-container; sleep 6
say "SOA setup (systemd units)"; incus exec soa-container -- bash /opt/soa/setup_soa_container.sh </dev/null | grep -v debconf || true

# ---------- Prometheus (prometheus-container) ----------
launch prometheus-container
incus config device get prometheus-container eth0 ipv4.address >/dev/null 2>&1 || \
  incus config device override prometheus-container eth0 ipv4.address=10.255.255.153
incus restart prometheus-container; sleep 6
say "Prometheus install + config"
incus exec prometheus-container -- bash -c 'command -v prometheus >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq prometheus >/dev/null 2>&1; }' </dev/null
incus file push -q "$HERE"/monitoring/prometheus.yml "$HERE"/monitoring/soa_alerts.yml prometheus-container/etc/prometheus/
# Incus metrics endpoint + trusted cert (per guide-3 setup) if not already present
incus config set core.metrics_address 10.255.255.1:8444 2>/dev/null || true
incus exec prometheus-container -- bash -c '[ -f /etc/prometheus/incus-metrics.crt ] || { cd /etc/prometheus && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -sha384 -keyout incus-metrics.key -nodes -out incus-metrics.crt -days 3650 -subj /CN=prometheus 2>/dev/null && chown prometheus incus-metrics.key && chmod 600 incus-metrics.key; }' </dev/null
incus file pull prometheus-container/etc/prometheus/incus-metrics.crt /tmp/incus-metrics.crt 2>/dev/null || true
incus config trust list -f csv 2>/dev/null | grep -q 'prometheus,metrics' || incus config trust add-certificate /tmp/incus-metrics.crt --type=metrics --name prometheus 2>/dev/null || true
incus exec prometheus-container -- bash -c 'promtool check config /etc/prometheus/prometheus.yml >/dev/null && systemctl restart prometheus' </dev/null
say "prometheus: $(incus exec prometheus-container -- systemctl is-active prometheus </dev/null)"

# ---------- Apache victim + Wazuh agent (apache-container) ----------
launch apache-container "images:ubuntu/22.04"
incus config device get apache-container eth0 ipv4.address >/dev/null 2>&1 || \
  incus config device override apache-container eth0 ipv4.address=10.255.255.241
incus start apache-container 2>/dev/null || true; sleep 4
incus exec apache-container -- bash -c 'command -v apache2ctl >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq apache2 curl iptables >/dev/null; }' </dev/null
say "apache: $(incus exec apache-container -- systemctl is-active apache2 </dev/null)"
echo "(Wazuh server + agent enrolment: see README; not re-run here to save RAM/time.)"

say "DONE — core lab"; incus list -c ns4 -f csv
free -m | awk '/Mem/{print "memory: used",$3,"MB, avail",$7,"MB"}'
