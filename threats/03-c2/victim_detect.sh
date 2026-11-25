#!/bin/bash
# Threat 3 (C2) — configure C2 detection on the VICTIM (apache-container) Wazuh agent.
# Run INSIDE apache-container. Idempotent (safe to re-run; it REPLACES the c2check block).
#
# Detection angles:
#   1. command monitoring (every 15s): flag any ESTABLISHED outbound TCP the web
#      server INITIATED to a lab host — a web server serves :80, it never dials out,
#      so an outbound connection is a reverse shell. This is PORT-AGNOSTIC: it catches
#      4444, 443, 8080, a randomized port — anything — not just the demo port.
#      Emits "C2CHECK peer=<ip:port> local=<ip:port> proc=<...>" -> rule 100300.
#   2. FIM realtime on /root/loot (a payload drop dir) -> file-added alerts (rule 100301).
set -e
OSSEC=/var/ossec/etc/ossec.conf
mkdir -p /root/loot

# Port-agnostic reverse-shell detector. Excludes the server's own listeners
# (local :80/:443/:22) and benign peers (DNS :53, Wazuh manager :1514/:1515, loopback).
C2CMD='ss -Hntp state established | awk '"'"'$3 !~ /:(80|443|22)$/ && $4 ~ /^10\.255\.255\./ && $4 !~ /:(53|1514|1515)$/ {print "C2CHECK peer="$4" local="$3" proc="$NF}'"'"''

python3 - "$OSSEC" "$C2CMD" <<'PY'
import sys, re
p, c2cmd = sys.argv[1], sys.argv[2]
s = open(p).read()

# 1) Remove any previous c2check localfile block, then insert the current one.
s = re.sub(r'\s*<localfile>\s*<log_format>full_command</log_format>.*?<alias>c2check</alias>.*?</localfile>',
           '', s, flags=re.S)

block = f"""  <localfile>
    <log_format>full_command</log_format>
    <command>{c2cmd}</command>
    <alias>c2check</alias>
    <frequency>15</frequency>
  </localfile>

"""
# 2) auth.log (logins / sudo) — add once if not already monitored.
if '/var/log/auth.log' not in s:
    block += """  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

"""
i = s.index('</ossec_config>')
s = s[:i] + block + s[i:]

# 3) Realtime FIM on the loot drop dir.
if 'realtime="yes" check_all="yes" report_changes="yes">/root/loot' not in s and '<syscheck>' in s:
    s = s.replace('<syscheck>',
                  '<syscheck>\n    <directories realtime="yes" check_all="yes" report_changes="yes">/root/loot</directories>', 1)
open(p, 'w').write(s)
print("configured (port-agnostic c2check)")
PY

# Allow the agent to run the local monitoring command
grep -q 'logcollector.remote_commands=1' /var/ossec/etc/local_internal_options.conf 2>/dev/null \
  || echo 'logcollector.remote_commands=1' >> /var/ossec/etc/local_internal_options.conf
systemctl restart wazuh-agent
sleep 5; systemctl is-active wazuh-agent
