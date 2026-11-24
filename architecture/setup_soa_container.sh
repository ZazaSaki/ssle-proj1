#!/bin/bash
# Runs INSIDE soa-container. Expects the code in /opt/soa.
# Installs dependencies and creates one systemd unit per SOA component.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-flask python3-requests python3-prometheus-client \
    prometheus-node-exporter >/dev/null

unit() {  # unit <name> <script> [ENV=VAL ...]
    local name=$1 script=$2; shift 2
    local envs=""
    for e in "$@"; do envs+="Environment=$e"$'\n'; done
    cat > /etc/systemd/system/soa-$name.service <<EOF
[Unit]
Description=SOA $name
After=network-online.target soa-registry.service

[Service]
WorkingDirectory=/opt/soa
ExecStart=/usr/bin/python3 -u /opt/soa/$script
$envs
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

unit registry  registry.py
unit storage-a storage_service.py PORT=5002 RACK=rack01 NODE=node01
unit storage-b storage_service.py PORT=5012 RACK=rack02 NODE=node04
unit ingestion ingestion_service.py PORT=5001 HOST=10.255.255.204
unit analytics analytics_service.py PORT=5003 HOST=10.255.255.204
unit sensor    sensor.py INTERVAL=2 INSTANCE=001
unit client    client.py INTERVAL=3
unit exporter  health_exporter.py INTERVAL=5

systemctl daemon-reload
for s in registry storage-a storage-b ingestion analytics sensor client exporter; do
    systemctl enable --now soa-$s >/dev/null 2>&1
    [ $s = registry ] && sleep 2
done
systemctl enable --now prometheus-node-exporter >/dev/null 2>&1
sleep 5
for s in registry storage-a storage-b ingestion analytics sensor client exporter; do
    echo "soa-$s: $(systemctl is-active soa-$s)"
done
echo "node-exporter: $(systemctl is-active prometheus-node-exporter)"
