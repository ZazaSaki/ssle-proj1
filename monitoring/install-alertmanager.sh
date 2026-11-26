#!/bin/bash
# Install + wire Alertmanager into the existing Prometheus plane (prometheus-container).
# Standalone and idempotent, so it does not touch siem/install_siem.sh or lab/genesis.sh.
#
#   Run on the VM:  bash projeto1/monitoring/install-alertmanager.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
C=prometheus-container

echo "=== installing prometheus-alertmanager in $C (if missing) ==="
incus exec "$C" -- bash -c 'command -v prometheus-alertmanager >/dev/null 2>&1 || command -v alertmanager >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq prometheus-alertmanager >/dev/null 2>&1; }' </dev/null

echo "=== pushing config ==="
incus file push -q "$HERE"/monitoring/alertmanager.yml "$C"/etc/prometheus/alertmanager.yml
incus file push -q "$HERE"/monitoring/prometheus.yml   "$C"/etc/prometheus/prometheus.yml

echo "=== (re)starting alertmanager + prometheus ==="
incus exec "$C" -- bash -c '
  # Debian ships the unit as prometheus-alertmanager; point it at our config.
  install -d /etc/default
  if systemctl list-unit-files | grep -q "^prometheus-alertmanager"; then
    sed -i "s#^ARGS=.*#ARGS=\"--config.file=/etc/prometheus/alertmanager.yml --storage.path=/var/lib/prometheus/alertmanager\"#" /etc/default/prometheus-alertmanager 2>/dev/null || \
      echo "ARGS=\"--config.file=/etc/prometheus/alertmanager.yml --storage.path=/var/lib/prometheus/alertmanager\"" > /etc/default/prometheus-alertmanager
    amtool check-config /etc/prometheus/alertmanager.yml >/dev/null 2>&1 || true
    systemctl enable prometheus-alertmanager >/dev/null 2>&1 || true; systemctl restart prometheus-alertmanager
  fi
  promtool check config /etc/prometheus/prometheus.yml >/dev/null && systemctl restart prometheus
' </dev/null

sleep 3
echo "=== status ==="
incus exec "$C" -- bash -c 'echo "alertmanager: $(systemctl is-active prometheus-alertmanager 2>/dev/null)"; echo "prometheus:   $(systemctl is-active prometheus)"; ss -tlnp 2>/dev/null | grep -E ":9093|:9090" | head' </dev/null
