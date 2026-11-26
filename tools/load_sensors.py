#!/usr/bin/env python3
# Multi-sensor load generator (run INSIDE a client container).
#
# Emulates ONE node that hosts N sensors: N threads, each a distinct hierarchical
# identity, all from this container's single source IP. Optionally adds a flood that
# reuses ONE identity. Prints a JSON summary: accepted (200), rate-limited (429),
# failed (connection dropped, e.g. by a per-IP iptables limiter), throughput and p95.
#
#   python3 load_sensors.py --ingest http://10.255.255.204:5001/ingest \
#       --sensors 50 --duration 15 [--interval 0] [--flood-id <id> --flood-threads 2]
import argparse, json, random, threading, time
import urllib.request, urllib.error

def post(url, device_id, timeout=3.0):
    body = json.dumps({"device_id": device_id,
                       "temperature": round(random.uniform(20, 30), 2),
                       "unit": "C"}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, (time.perf_counter() - t0) * 1000
    except urllib.error.HTTPError as e:
        return e.code, (time.perf_counter() - t0) * 1000       # e.g. 429
    except Exception:
        return 0, (time.perf_counter() - t0) * 1000            # connection dropped/timeout

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ingest", required=True)
    ap.add_argument("--sensors", type=int, default=50)
    ap.add_argument("--duration", type=float, default=15.0)
    ap.add_argument("--interval", type=float, default=0.0, help="per-sensor sleep; 0 = closed loop")
    ap.add_argument("--flood-id", default=None)
    ap.add_argument("--flood-threads", type=int, default=0)
    a = ap.parse_args()

    stop = time.monotonic() + a.duration
    lock = threading.Lock()
    agg = {"ok": 0, "limited": 0, "failed": 0}        # legitimate sensors
    flood = {"ok": 0, "limited": 0, "failed": 0}      # the reused-identity flood
    lat = []

    def sensor(i):
        did = f"pt.aveiro.dc1.rack09.node{i:03d}/temp-sensor#{i:03d}"
        while time.monotonic() < stop:
            st, ms = post(a.ingest, did)
            with lock:
                agg["ok" if st in (200,201) else "limited" if st==429 else "failed"] += 1
                lat.append(ms)
            if a.interval > 0: time.sleep(a.interval)

    def flooder():
        while time.monotonic() < stop:
            st, ms = post(a.ingest, a.flood_id)
            with lock:
                flood["ok" if st in (200,201) else "limited" if st==429 else "failed"] += 1

    threads = [threading.Thread(target=sensor, args=(i,)) for i in range(a.sensors)]
    if a.flood_id:
        threads += [threading.Thread(target=flooder) for _ in range(max(1, a.flood_threads))]
    t0 = time.perf_counter()
    for t in threads: t.start()
    for t in threads: t.join()
    elapsed = time.perf_counter() - t0

    lat.sort()
    p = lambda q: round(lat[min(len(lat)-1, int(q*len(lat)))], 1) if lat else None
    total = agg["ok"] + agg["limited"] + agg["failed"]
    print(json.dumps({
        "sensors": a.sensors, "duration_s": round(elapsed, 1),
        "legit_ok": agg["ok"], "legit_429": agg["limited"], "legit_failed": agg["failed"],
        "legit_served_pct": round(100*agg["ok"]/total, 1) if total else None,
        "throughput_rps": round(agg["ok"]/elapsed, 1) if elapsed else None,
        "p50_ms": p(0.50), "p95_ms": p(0.95),
        "flood_ok": flood["ok"], "flood_429": flood["limited"], "flood_failed": flood["failed"],
    }))

if __name__ == "__main__":
    main()
