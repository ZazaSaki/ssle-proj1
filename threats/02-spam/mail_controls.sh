#!/bin/bash
# Threat 2 (Spam) — mail-server readying + reversible response controls.
# Run INSIDE mail-container.
#
#   ready            ensure spamd running + content_filter pipeline healthy
#   quarantine on    HOLD any message SpamAssassin flagged (X-Spam-Flag: YES)
#   quarantine off
#   ratelimit on     Postfix anvil per-client SMTP message-rate limit (volume spam)
#   ratelimit off
#   status           show queue, controls, spamd state
set -euo pipefail
HC=/etc/postfix/header_checks

case "${1:-}:${2:-}" in
  ready:*)
    systemctl enable --now spamassassin
    postconf -e 'content_filter = spamassassin' 2>/dev/null || true
    systemctl reload postfix
    echo "spamassassin: $(systemctl is-active spamassassin); postfix: $(systemctl is-active postfix)" ;;

  quarantine:on)
    grep -q 'X-Spam-Flag: YES' "$HC" 2>/dev/null || echo '/^X-Spam-Flag: YES/ HOLD' >> "$HC"
    postconf -e "header_checks = regexp:$HC"
    systemctl reload postfix
    echo "quarantine ON — flagged spam goes to the HOLD queue, not the mailbox" ;;
  quarantine:off)
    sed -i '/X-Spam-Flag: YES/d' "$HC" 2>/dev/null || true
    postconf -e 'header_checks =' ; systemctl reload postfix
    postsuper -H ALL 2>/dev/null || true   # release anything held
    echo "quarantine OFF" ;;

  ratelimit:on)
    # Subject localhost too (lab): by default mynetworks is exempt from anvil limits.
    postconf -e 'smtpd_client_event_limit_exceptions ='
    postconf -e 'anvil_rate_time_unit = 60s'
    postconf -e 'smtpd_client_message_rate_limit = 10'   # >10 msgs/60s/client -> 450 reject
    systemctl reload postfix
    echo "ratelimit ON — >10 messages/60s per client IP are rejected (4.7.1)" ;;
  ratelimit:off)
    postconf -X smtpd_client_message_rate_limit smtpd_client_event_limit_exceptions anvil_rate_time_unit 2>/dev/null || true
    systemctl reload postfix
    echo "ratelimit OFF" ;;

  status:*)
    echo "spamassassin: $(systemctl is-active spamassassin)"
    echo "content_filter: $(postconf -h content_filter)"
    echo "header_checks:  $(postconf -h header_checks)"
    echo "rate limit:     $(postconf -h smtpd_client_message_rate_limit) msg / $(postconf -h anvil_rate_time_unit)"
    echo "HOLD queue:"; postqueue -p | tail -n +2 | grep -c '!' || true
    mailq | tail -3 ;;
  *) echo "usage: $0 ready|quarantine on|off|ratelimit on|off|status"; exit 1 ;;
esac
