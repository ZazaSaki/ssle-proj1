#!/bin/bash
# Threat 2 (Spam) — enrol a Wazuh agent on mail-container and feed it the mail log.
# Run INSIDE mail-container.  Manager = 10.255.255.4.
set -e
export DEBIAN_FRONTEND=noninteractive
MANAGER=10.255.255.4

if ! dpkg -l wazuh-agent >/dev/null 2>&1; then
  apt-get install -y -qq gpg curl >/dev/null
  curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring \
    --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && chmod 644 /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list
  apt-get update -qq
  WAZUH_MANAGER="$MANAGER" apt-get install -y -qq wazuh-agent >/dev/null
fi

# Feed the mail log to the agent (idempotent)
if ! grep -q '/var/log/mail.log' /var/ossec/etc/ossec.conf; then
  python3 - <<'PY'
p='/var/ossec/etc/ossec.conf'; s=open(p).read()
blk="  <localfile>\n    <log_format>syslog</log_format>\n    <location>/var/log/mail.log</location>\n  </localfile>\n\n"
i=s.index('</ossec_config>'); open(p,'w').write(s[:i]+blk+s[i:])
PY
fi
grep -A1 '<address>' /var/ossec/etc/ossec.conf | head -2
systemctl daemon-reload; systemctl enable --now wazuh-agent
sleep 8; systemctl is-active wazuh-agent
