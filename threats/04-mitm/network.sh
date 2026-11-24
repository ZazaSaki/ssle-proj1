#!/bin/bash
# Threat 4 (MitM, bonus) — build an isolated topology where the client's route to the
# target MUST pass through an on-path interceptor. Run ON THE VM.
#
#   client (mitm-net only) --default gw--> interceptor (mitm-net + incus-default) --> apache
#
# No ARP spoofing, no external traffic: the interceptor is the *legitimate* gateway, which
# models a hijacked route. Return path works via MASQUERADE on the interceptor.
set -euo pipefail
IMG=images:debian/trixie
MNET=mitm-net
INT_MNET=10.66.0.2      # interceptor, mitm-net side (client's gateway)
CLIENT_IP=10.66.0.10
APACHE=10.255.255.241

incus network show $MNET >/dev/null 2>&1 || \
  incus network create $MNET ipv4.address=10.66.0.1/24 ipv4.nat=false ipv6.address=none

launch(){ incus info "$1" >/dev/null 2>&1 && { incus start "$1" 2>/dev/null||true; echo "$1 exists"; } || { incus launch "$IMG" "$1"; sleep 6; }; }

# interceptor: eth0 on incus-default (to reach apache), eth1 on mitm-net
launch mitm-interceptor
incus config device get mitm-interceptor eth1 network >/dev/null 2>&1 || \
  incus config device add mitm-interceptor eth1 nic network=$MNET name=eth1 ipv4.address=$INT_MNET
# client: ONLY on mitm-net
if ! incus info mitm-client >/dev/null 2>&1; then
  incus init $IMG mitm-client
  incus config device remove mitm-client eth0 2>/dev/null || true
  incus config device add mitm-client eth0 nic network=$MNET name=eth0 ipv4.address=$CLIENT_IP
  incus start mitm-client; sleep 6
else incus start mitm-client 2>/dev/null || true; fi

# force the client's default route through the interceptor
incus exec mitm-client -- ip route replace default via $INT_MNET </dev/null 2>/dev/null || true
echo "topology:"; incus list mitm -c ns4 -f csv
echo "client route to apache:"; incus exec mitm-client -- ip route get $APACHE </dev/null 2>&1 | head -1
