#!/bin/bash
# Wazuh active-response (runs ON THE VICTIM agent). Contains a live C2 channel,
# PORT-AGNOSTIC to match the detection: it finds every outbound ESTABLISHED
# connection the web server initiated to a lab host (a web server never dials out),
# kills the owning process, and DROPs egress to that peer — on any port, not just 4444.
#
# Wazuh 4.x AR protocol: a JSON object on stdin with .command = "add" | "delete".
# Uses a dedicated OUTPUT chain (C2-CONTAIN) so "delete" is a clean flush.
# Install at /var/ossec/active-response/bin/c2-contain.sh on the agent (chmod 750,
# owner root:wazuh).
LOG=/var/ossec/logs/active-responses.log
CHAIN=C2-CONTAIN
read -r INPUT
CMD=$(echo "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[a-z]+"' | grep -oE '(add|delete)')
ts(){ date '+%F %T'; }

# suspicious = established, local port not a server port, peer a lab host, not DNS/Wazuh
suspects(){
  ss -Hntp state established | awk '$3 !~ /:(80|443|22)$/ && $4 ~ /^10\.255\.255\./ && $4 !~ /:(53|1514|1515)$/'
}

ensure_chain(){
  iptables -N $CHAIN 2>/dev/null || true
  iptables -C OUTPUT -j $CHAIN 2>/dev/null || iptables -I OUTPUT -j $CHAIN
}

case "$CMD" in
  add)
    ensure_chain
    SUS=$(suspects)                      # snapshot once (before we start killing)
    if [ -z "$SUS" ]; then
      echo "$(ts) c2-contain: no live C2 connection found at run time" >> $LOG
    else
      # block egress to each distinct peer IP, and kill the owning process
      echo "$SUS" | while read -r line; do
        peer=$(echo "$line" | awk '{print $4}'); peerip=${peer%:*}
        iptables -C $CHAIN -d "$peerip" -j DROP 2>/dev/null || iptables -A $CHAIN -d "$peerip" -j DROP
        echo "$(ts) c2-contain: blocked egress to $peerip" >> $LOG
        for pid in $(echo "$line" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
          kill -9 "$pid" 2>/dev/null && echo "$(ts) c2-contain: killed pid $pid (peer $peer)" >> $LOG
        done
      done
    fi
    ;;
  delete)
    iptables -D OUTPUT -j $CHAIN 2>/dev/null
    iptables -F $CHAIN 2>/dev/null
    iptables -X $CHAIN 2>/dev/null
    echo "$(ts) c2-contain: cleared containment ($CHAIN)" >> $LOG ;;
  *)
    echo "$(ts) c2-contain: unknown command '$CMD'" >> $LOG ;;
esac
exit 0
