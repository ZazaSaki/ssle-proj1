# Service Registry: registration, discovery, health checking and load balancing
import os
import threading
import time
from collections import deque
from datetime import datetime, timezone

import requests
from flask import Flask, jsonify, request, send_from_directory

app = Flask(__name__)
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

HEARTBEAT_TTL = 15   # seconds without heartbeat before eviction
PROBE_INTERVAL = 10  # seconds between active /health probes

# services[name][instance_id] = {url, location, registered_at, last_heartbeat, probe_*}
services = {}
rr_counters = {}     # round-robin position per service name
events = deque(maxlen=200)  # register / unregister / evict history (for monitoring)
started_at = time.time()
lock = threading.Lock()


def now():
    return time.time()


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat() if ts else None


def log_event(kind, name, instance_id, detail=""):
    events.append({"ts": iso(now()), "type": kind, "service": name,
                   "instance_id": instance_id, "detail": detail})


def view(instance_id, info):
    return {
        "instance_id": instance_id,
        "url": info["url"],
        "location": info["location"],
        "registered_at": iso(info["registered_at"]),
        "last_heartbeat": iso(info["last_heartbeat"]),
        "heartbeat_age_s": round(now() - info["last_heartbeat"], 1),
        "last_probe": iso(info.get("last_probe")),
        "probe_ok": info.get("probe_ok"),
        "probe_latency_ms": info.get("probe_latency_ms"),
    }


def evict(name, instance_id, reason):
    with lock:
        if services.get(name, {}).pop(instance_id, None) is not None:
            print(f"evicted {instance_id}: {reason}")
            log_event("unregister" if reason == "unregistered" else "evict", name, instance_id, reason)
        if name in services and not services[name]:
            del services[name]


@app.after_request
def cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    return resp


# ---------- Registration ----------

@app.route("/register", methods=["POST"])
def register():
    data = request.get_json(silent=True) or {}
    name, url = data.get("name"), data.get("url")
    if not name or not url:
        return jsonify({"error": "Missing name or url"}), 400
    location = data.get("location", "unknown")
    instance_id = data.get("instance_id") or f"{location}/{name}#{url}"
    ts = now()
    with lock:
        services.setdefault(name, {})[instance_id] = {
            "url": url, "location": location, "registered_at": ts, "last_heartbeat": ts,
        }
        log_event("register", name, instance_id, url)
    print(f"registered {instance_id} -> {url}")
    return jsonify({"message": f"{name} registered", "instance_id": instance_id}), 200


@app.route("/unregister", methods=["DELETE"])
def unregister():
    data = request.get_json(silent=True) or {}
    name, instance_id = data.get("name"), data.get("instance_id")
    with lock:
        found = instance_id in services.get(name, {})
    if not found:
        return jsonify({"error": "Not found"}), 404
    evict(name, instance_id, "unregistered")
    return jsonify({"message": f"{instance_id} unregistered"}), 200


@app.route("/heartbeat", methods=["PUT"])
def heartbeat():
    data = request.get_json(silent=True) or {}
    name, instance_id = data.get("name"), data.get("instance_id")
    with lock:
        info = services.get(name, {}).get(instance_id)
        if not info:
            return jsonify({"error": "Not registered"}), 404
        info["last_heartbeat"] = now()
    return jsonify({"message": "ok"}), 200


# ---------- Discovery ----------

def filtered(name=None, location=None):
    with lock:
        out = {}
        for svc, instances in services.items():
            if name and svc != name:
                continue
            items = [view(i, info) for i, info in instances.items()
                     if not location or info["location"].startswith(location)]
            if items:
                out[svc] = items
        return out


@app.route("/services", methods=["GET"])
def list_services():
    # ?location=pt.aveiro  -> everything running in that part of the hierarchy
    return jsonify(filtered(location=request.args.get("location")))


@app.route("/services/<name>", methods=["GET"])
def get_service(name):
    result = filtered(name=name, location=request.args.get("location"))
    if not result:
        return jsonify({"error": "Not found"}), 404
    return jsonify(result[name])


@app.route("/discover/<name>", methods=["GET"])
def discover(name):
    """Return ONE instance, round-robin (load balancing).
    ?near=<location prefix> prefers instances in that part of the hierarchy."""
    near = request.args.get("near")
    with lock:
        instances = sorted(services.get(name, {}).items())
        if not instances:
            return jsonify({"error": "No instances available"}), 404
        if near:
            close = [i for i in instances if i[1]["location"].startswith(near)]
            instances = close or instances
        idx = rr_counters.get(name, 0) % len(instances)
        rr_counters[name] = idx + 1
        instance_id, info = instances[idx]
        return jsonify(view(instance_id, info))


# ---------- Monitoring ----------

@app.route("/events", methods=["GET"])
def get_events():
    limit = request.args.get("limit", 50, type=int)
    return jsonify(list(events)[-limit:][::-1])


@app.route("/health", methods=["GET"])
def health():
    with lock:
        count = sum(len(v) for v in services.values())
    return jsonify({"status": "up", "service": "registry", "uptime_s": round(now() - started_at, 1),
                    "instances": count, "heartbeat_ttl_s": HEARTBEAT_TTL,
                    "probe_interval_s": PROBE_INTERVAL})


@app.route("/", methods=["GET"])
@app.route("/dashboard", methods=["GET"])
def dashboard():
    return send_from_directory(BASE_DIR, "dashboard.html")


# ---------- Health checking ----------

def health_checker():
    while True:
        time.sleep(PROBE_INTERVAL)
        with lock:
            snapshot = [(n, i, dict(info)) for n, inst in services.items() for i, info in inst.items()]
        for name, instance_id, info in snapshot:
            # Passive check: heartbeat expired
            if now() - info["last_heartbeat"] > HEARTBEAT_TTL:
                evict(name, instance_id, "heartbeat timeout")
                continue
            # Active check: probe /health
            t0 = time.perf_counter()
            try:
                res = requests.get(f"{info['url']}/health", timeout=2)
                ok = res.status_code == 200
                reason = f"health returned {res.status_code}"
            except requests.RequestException:
                ok, reason = False, "health probe failed"
            if not ok:
                evict(name, instance_id, reason)
                continue
            with lock:
                live = services.get(name, {}).get(instance_id)
                if live:
                    live.update(probe_ok=True, last_probe=now(),
                                probe_latency_ms=round((time.perf_counter() - t0) * 1000, 1))


if __name__ == "__main__":
    threading.Thread(target=health_checker, daemon=True).start()
    app.run(host="localhost", port=int(os.environ.get("PORT", 5050)), threaded=True)
