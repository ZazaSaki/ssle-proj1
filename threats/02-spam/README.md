# Threat 2 — Junk Email / Spam

**Syllabus:** Junk email (+ Reputation Systems). **Guide:** Practical Guide 6.

## Description & relevance
An open or weakly-filtered mail server lets an attacker inject unsolicited mail —
social-engineering lures (fraud) and sheer volume (availability / storage / cost). A
large-scale operator runs mail for many tenants, so content filtering, quarantine and
per-client rate limiting are core hygiene.

## Architecture
`mail-container`: Postfix (MTA, local delivery) + Dovecot (IMAP/POP3) + SpamAssassin.
Pipeline: `smtpd → content_filter=spamassassin → spamc → spamd → SpamAssassin`. A Wazuh
agent ships `/var/log/mail.log`.

## How it is exploited — `spam.py`
`gtube` (deterministic spam), `social` (phishing/fraud lures), `volume N` (flood).

## Monitoring (SIEM)
Decoder `wazuh-rules/spamassassin_decoders.xml` extracts the score; rules
`wazuh-rules/spam_rules.xml`:
- 100201 spam verdict, 100202 high-confidence (score ≥ 100), 100203 campaign (≥10/60 s).

## Action-response (`mail_controls.sh`, reversible)
- `quarantine on` — HOLD flagged mail (Postfix `header_checks`), not the mailbox.
- `ratelimit on` — Postfix anvil per-client message-rate limit (volume).
- Reputation: Bayes auto-learn (content) + CDB client-access blocklist pattern (sender IP).

## Run it
```bash
# on the VM
bash lab/control.sh spam up                                   # start mail-container
incus exec mail-container -- bash /root/02-spam/mail_controls.sh ready
incus exec mail-container -- bash /root/02-spam/mail_controls.sh quarantine on
incus exec mail-container -- python3 /root/02-spam/spam.py gtube
incus exec mail-container -- python3 /root/02-spam/spam.py social
incus exec mail-container -- python3 /root/02-spam/spam.py volume 15
# alerts: incus exec wazuh-container -- grep '"id":"1002' /var/ossec/logs/alerts/alerts.json
incus exec mail-container -- bash /root/02-spam/mail_controls.sh ratelimit on   # mitigate volume
incus exec mail-container -- bash /root/02-spam/mail_controls.sh quarantine off # cleanup
incus exec mail-container -- bash /root/02-spam/mail_controls.sh ratelimit off
bash lab/control.sh spam down
```

Setup from scratch: `setup_agent.sh` (Wazuh agent) + install the two XML files on the
manager (`/var/ossec/etc/{decoders,rules}/`), restart `wazuh-manager`.

Evidence: [`evidence/poc-run.md`](evidence/poc-run.md).
