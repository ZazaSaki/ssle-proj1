# Threat 2 (Spam) — PoC evidence

Mail server: `mail-container` (10.255.255.206) — Postfix (local) + Dovecot (IMAP/POP3) +
SpamAssassin (spamd) with the content_filter pipeline
`smtpd → content_filter=spamassassin → spamc → spamd`. Wazuh agent 002 ships
`/var/log/mail.log` to the manager. Date 2026-11-24. Lab only (delivers to localhost).

## Readying fix
The pipeline was wired but **spamd was not running**. On Ubuntu the daemon is
`spamassassin.service` (the guide's `/etc/default/spamd` does not apply; Ubuntu uses
`/etc/default/spamassassin`). Starting it made scoring work:

```
direct spamc GTUBE  -> X-Spam-Flag: YES, score=1003.7/5.0
via SMTP (full path) -> Subject rewritten "*****SPAM*****", score=1000.3/5.0, delivered
```

## Attack (`spam.py`)
- `gtube`  : 1 guaranteed-spam GTUBE message (deterministic high score).
- `social` : 3 social-engineering lures (Nigerian prince, lottery/10000th visitor, bank phish).
- `volume` : N identical GTUBE-laden messages (availability / storage / cost angle).

## Detection — SpamAssassin score + Wazuh rules
spamd logs to mail.log: `spamd: identified spam (1003.7/5.0) for root:65534 ...`.
Custom decoder (`spamassassin_decoders.xml`, PCRE2) extracts `sa_score`/`sa_threshold`/`sa_user`.
Rules (`spam_rules.xml`):

| rule | level | fires on | observed |
|---|---|---|---|
| 100201 | 5 | any SpamAssassin spam verdict | ✓ (social lures) |
| 100202 | 10 | high-confidence spam (score ≥ 100) | ✓ 56× (GTUBE) |
| 100203 | 12 | **campaign**: ≥10 spam in 60 s (frequency) | ✓ 3× (volume), agent=mail-container |

## Response (reversible, `mail_controls.sh`)

**Quarantine** (`quarantine on`): Postfix `header_checks` HOLDs any `X-Spam-Flag: YES`
message → the HOLD queue instead of the mailbox.
- gtube+social+volume(12) = 16 messages sent → **16 held in queue, 0 newly delivered**.

**SMTP rate limit** (`ratelimit on`): Postfix anvil `smtpd_client_message_rate_limit=10`
per 60 s per client IP (lab: `smtpd_client_event_limit_exceptions=` so localhost is also
limited).

| send 15 messages | accepted | rejected |
|---|---|---|
| without limit | 15 | 0 |
| with limit | **10** | **5** (`Message delivery request rate limit exceeded`) |

## Reputation-system tie-in
SpamAssassin's Bayes auto-learn (`bayes_auto_learn 1`) builds a local content-reputation
model. For sender/IP reputation, the same CDB-list + `firewall-drop`/`check_client_access`
pattern used in Guide 4 (cybercrime blocklist) applies: a Wazuh active-response on rule
100203 can append the offending client IP to a Postfix `check_client_access` map. (In this
lab all mail originates from localhost, so IP reputation is described rather than demonstrated.)

## Post-mortem / limitations
- GTUBE guarantees a verdict; real spam needs tuned rules + trained Bayes → false positives
  are the real risk (quarantine, not reject, mitigates that).
- Content filtering is post-queue, so it costs CPU per message; the rate limit (pre-queue)
  is what protects against pure volume.
