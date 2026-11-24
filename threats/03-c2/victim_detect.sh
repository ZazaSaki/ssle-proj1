#!/bin/bash
# Threat 3 (C2) — configure C2 detection on the VICTIM (apache-container) Wazuh agent.
# Run INSIDE apache-container. Adds:
#   1. command monitoring: every 15s, flag any ESTABLISHED TCP connection to :4444
#      (the reverse-shell C2 port) -> emits "C2CHECK peer=<ip:port>"
#   2. FIM realtime on /root/loot (a payload drop dir) -> file-added alerts
set -e
OSSEC=/var/ossec/etc/ossec.conf
mkdir -p /root/loot

python3 - "$OSSEC" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
add=""
if 'C2CHECK' not in s:
    add += """  <localfile>
    <log_format>full_command</log_format>
    <command>ss -Hntp state established dst :4444 | awk '{print "C2CHECK peer="$4" proc="$6}'</command>
    <alias>c2check</alias>
    <frequency>15</frequency>
  </localfile>

"""
if '/root/loot' not in s:
    add += """  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

"""
if add:
    i=s.index('</ossec_config>'); s=s[:i]+add+s[i:]
# ensure syscheck watches /root/loot in realtime
if '/root/loot' not in s or 'realtime="yes">/root/loot' not in s:
    import re
    if '<syscheck>' in s and 'realtime="yes">/root/loot' not in s:
        s=s.replace('<syscheck>', '<syscheck>\n    <directories realtime="yes" check_all="yes" report_changes="yes">/root/loot</directories>',1)
open(p,'w').write(s)
print("configured")
PY

# Allow the agent to run the local monitoring command
grep -q 'logcollector.remote_commands=1' /var/ossec/etc/local_internal_options.conf 2>/dev/null \
  || echo 'logcollector.remote_commands=1' >> /var/ossec/etc/local_internal_options.conf
systemctl restart wazuh-agent
sleep 5; systemctl is-active wazuh-agent
