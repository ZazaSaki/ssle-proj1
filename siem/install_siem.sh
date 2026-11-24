#!/bin/bash
# Install ALL project SIEM content onto the Wazuh manager + register active-responses.
# Run ON THE VM. Idempotent. Assumes wazuh-container is up with a working manager and
# the agents (apache-container=001, mail-container=002) are enrolled.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)   # projeto1/siem

echo "== push decoders + rules"
incus file push -q "$HERE"/rules/spamassassin_decoders.xml wazuh-container/var/ossec/etc/decoders/spamassassin_decoders.xml
for f in spam_rules.xml c2_rules.xml dos_rules.xml; do
  incus file push -q "$HERE/rules/$f" "wazuh-container/var/ossec/etc/rules/$f"
done
echo "== push active-response script to the victim agent"
incus file push -q "$HERE"/active-response/c2-contain.sh apache-container/var/ossec/active-response/bin/c2-contain.sh
incus exec apache-container -- bash -c 'chmod 750 /var/ossec/active-response/bin/c2-contain.sh; chown root:wazuh /var/ossec/active-response/bin/c2-contain.sh' </dev/null

echo "== fix ownership + register active-responses on the manager"
incus exec wazuh-container -- bash -c '
chown wazuh:wazuh /var/ossec/etc/decoders/spamassassin_decoders.xml /var/ossec/etc/rules/*.xml
C=/var/ossec/etc/ossec.conf
add_ar() {  # add_ar <command> <rules_id>
  grep -q "rules_id>$2<" "$C" && return
  cat >> "$C" <<XML
<ossec_config>
  <active-response>
    <command>$1</command>
    <location>local</location>
    <rules_id>$2</rules_id>
    <timeout>120</timeout>
  </active-response>
</ossec_config>
XML
}
grep -q "name>c2-contain<" "$C" || cat >> "$C" <<XML
<ossec_config>
  <command>
    <name>c2-contain</name>
    <executable>c2-contain.sh</executable>
    <timeout_allowed>yes</timeout_allowed>
  </command>
</ossec_config>
XML
add_ar firewall-drop 100110   # DoS HTTP flood
add_ar c2-contain   100300    # C2 channel
# spam response is at the Postfix layer (mail_controls.sh), not a Wazuh AR
/var/ossec/bin/wazuh-analysisd -t >/dev/null && echo "config OK"
systemctl restart wazuh-manager
' </dev/null
sleep 5
echo "== manager: $(incus exec wazuh-container -- systemctl is-active wazuh-manager </dev/null)"
