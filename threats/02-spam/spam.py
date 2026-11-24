#!/usr/bin/env python3
"""Threat 2 (Spam) attacker. Run INSIDE mail-container (lab only, delivers to
localhost). Two spam flavours from the course notes:

  volume   : many messages fast (availability / storage / cost angle)
  social   : social-engineering lures (Nigerian prince, lottery, 10000th visitor)
  gtube    : one guaranteed-spam GTUBE message (deterministic high score)

Usage:  spam.py gtube
        spam.py social
        spam.py volume [N]        # default 30 messages
"""
import smtplib, sys, time

HOST, PORT = "127.0.0.1", 25
RCPT = "ubuntu@localhost"
GTUBE = "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X"

SOCIAL = [
    ("prince@royalfamily.ng", "Urgent Business Proposal",
     "Dear Friend, I am a prince and need your help to move $45,000,000. "
     "Send your bank details and a small fee to release the funds."),
    ("winner@mega-lottery.biz", "You WON the lottery!!!",
     "Congratulations! You are our 10000th visitor and have WON $1,000,000. "
     "Click http://claim-your-prize.biz and pay the processing fee now!"),
    ("security@yourbank.verify", "Account suspended - verify now",
     "Your account will be closed. Verify your password immediately at "
     "http://yourbank.verify-login.biz to avoid suspension."),
]

def send(sender, subject, body):
    msg = f"From: {sender}\r\nTo: {RCPT}\r\nSubject: {subject}\r\n\r\n{body}\r\n"
    with smtplib.SMTP(HOST, PORT, timeout=10) as s:
        s.sendmail(sender, [RCPT], msg)

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "gtube"
    if mode == "gtube":
        send("attacker@evil.test", "cheap meds + prize", GTUBE); print("sent 1 GTUBE")
    elif mode == "social":
        for i, (frm, subj, body) in enumerate(SOCIAL, 1):
            send(frm, subj, body); print(f"sent social #{i}: {subj!r}")
    elif mode == "volume":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 30
        t0 = time.time(); ok = rej = 0
        for i in range(n):
            try:
                send("blast@spammer.test", f"BUY NOW cheap meds #{i}",
                     f"Limited offer! {GTUBE}")   # GTUBE => every one scores as spam
                ok += 1
            except smtplib.SMTPException as e:
                rej += 1                           # e.g. rejected by Postfix rate limit
        print(f"volume: accepted={ok} rejected={rej} of {n} in {time.time()-t0:.1f}s")
    else:
        print(__doc__); sys.exit(1)

if __name__ == "__main__":
    main()
