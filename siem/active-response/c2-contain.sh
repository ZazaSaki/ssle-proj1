#!/bin/bash
# Wazuh active-response (runs ON THE VICTIM agent). Contains a live C2 channel:
#   - DROP all egress to the C2 port 4444 (kills the reverse shell)
#   - kill any process holding a connection to :4444
# Wazuh 4.x AR protocol: a JSON object on stdin with .command = "add" | "delete".
# Install at /var/ossec/active-response/bin/c2-contain.sh on the agent (chmod 750,
# owner root:wazuh).
LOG=/var/ossec/logs/active-responses.log
read -r INPUT
CMD=$(echo "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[a-z]+"' | grep -oE '(add|delete)')
PORT=4444

case "$CMD" in
  add)
    iptables -C OUTPUT -p tcp --dport $PORT -j DROP 2>/dev/null || iptables -I OUTPUT -p tcp --dport $PORT -j DROP
    # kill processes with an established connection to :4444
    for pid in $(ss -Hntp state established dst :$PORT 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
      kill -9 "$pid" 2>/dev/null && echo "$(date '+%F %T') c2-contain: killed pid $pid" >> $LOG
    done
    echo "$(date '+%F %T') c2-contain: blocked egress tcp/$PORT" >> $LOG ;;
  delete)
    iptables -D OUTPUT -p tcp --dport $PORT -j DROP 2>/dev/null
    echo "$(date '+%F %T') c2-contain: unblocked egress tcp/$PORT" >> $LOG ;;
  *)
    echo "$(date '+%F %T') c2-contain: unknown command '$CMD'" >> $LOG ;;
esac
exit 0
