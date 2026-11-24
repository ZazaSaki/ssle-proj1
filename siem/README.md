# SIEM (Wazuh) — consolidated detection & response

Wazuh manager on `wazuh-container` (10.255.255.4). Agents: `apache-container` (001),
`mail-container` (002). Install everything with `./install_siem.sh` (run on the VM).

## Incident types (≥3 required) and action-responses

| # | Threat | Rules | Detection source | Action-response |
|---|---|---|---|---|
| 1 | **DoS** (HTTP flood) | 100110 (freq 60/10s, `same_source_ip`) ← 100111 ← 31108 | Apache access.log | `firewall-drop` blocks the source IP (120 s) |
| 2 | **Spam** | 100201 / 100202 / 100203 (campaign, freq 10/60s) | spamd log via decoder | Postfix quarantine (HOLD) + SMTP rate limit (`mail_controls.sh`) |
| 3 | **C2 / APT** | 100300 (C2 connection) + 100301 (payload FIM) | command monitor + syscheck | `c2-contain.sh` kills the shell + drops egress tcp/4444 |

(Plus 100100 Shellshock → reputation blocklist + `firewall-drop`, from Guide 4.)

## Files
- `rules/spamassassin_decoders.xml`, `rules/spam_rules.xml` — spam.
- `rules/c2_rules.xml`, `active-response/c2-contain.sh` — C2.
- `rules/dos_rules.xml` — DoS (uses built-in `firewall-drop`).

## Design notes learned during build
- Wazuh **frequency** correlation counts prior *alerts* (level > 0). The built-in web
  200-access rule (31108) is level 0, so the DoS flood rule keys off a thin level-2 base
  (100111), not 31108 directly.
- full_command output is parsed by the built-in parent rule **530**; the C2 rule is its
  child (`if_sid 530`), not `decoded_as ossec`.
- SpamAssassin score extraction uses a **PCRE2** decoder regex (`os_regex` did not
  capture the `(score/threshold)` group reliably).
- Agent command monitoring needs `logcollector.remote_commands=1` in the agent's
  `local_internal_options.conf`.

## FCAPS Fault-Management mapping
Detect (rule fires) → Isolate (which agent/service) → Correlate (Prometheus metrics +
Wazuh events in the same window) → Resolve/Mitigate (action-response) → Post-mortem
(`threats/*/evidence/poc-run.md`).
