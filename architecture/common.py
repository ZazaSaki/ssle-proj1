# Shared helpers: hierarchical naming, registration, heartbeat and discovery
import atexit
import os
import signal
import sys
import threading
import time

import requests
from flask import g, request

REGISTRY_URL = os.environ.get("REGISTRY_URL", "http://localhost:5050")
HEARTBEAT_INTERVAL = 5
TIMEOUT = 3

# Location hierarchy: country.city.datacenter.rack.node
# e.g. "pt.aveiro.dc1.rack02.node03"
def location_from_env():
    parts = [
        os.environ.get("COUNTRY", "pt"),
        os.environ.get("REGION", "aveiro"),
        os.environ.get("DATACENTER", "dc1"),
        os.environ.get("RACK", "rack01"),
        os.environ.get("NODE", "node01"),
    ]
    return ".".join(parts)


def make_service_id(kind, location, instance):
    """Hierarchical ID: <location>/<service-kind>#<instance>.

    - the location prefix allows management (filter/aggregate per country, DC, rack...)
    - the service kind allows discovery (find all instances of "storage-service")
    - the instance suffix makes the ID unique (addressing)
    """
    return f"{location}/{kind}#{instance}"


def register(name, url, location, instance):
    instance_id = make_service_id(name, location, instance)
    res = requests.post(f"{REGISTRY_URL}/register", json={
        "name": name,
        "instance_id": instance_id,
        "url": url,
        "location": location,
    }, timeout=TIMEOUT)
    res.raise_for_status()
    return res.json()["instance_id"]


def unregister(name, instance_id):
    try:
        requests.delete(f"{REGISTRY_URL}/unregister",
                        json={"name": name, "instance_id": instance_id}, timeout=TIMEOUT)
    except requests.RequestException:
        pass


def start_heartbeat(name, url, location, instance, instance_id):
    def loop():
        while True:
            time.sleep(HEARTBEAT_INTERVAL)
            try:
                res = requests.put(f"{REGISTRY_URL}/heartbeat",
                                   json={"name": name, "instance_id": instance_id}, timeout=TIMEOUT)
                if res.status_code == 404:
                    # Registry forgot us (restart or eviction): register again
                    register(name, url, location, instance)
                    print(f"[{instance_id}] re-registered")
            except requests.RequestException as e:
                print(f"[{instance_id}] heartbeat failed: {e}")

    threading.Thread(target=loop, daemon=True).start()


def discover(name, near=None):
    """Ask the registry for one healthy instance (round-robin). Returns its URL or None."""
    params = {"near": near} if near else {}
    try:
        res = requests.get(f"{REGISTRY_URL}/discover/{name}", params=params, timeout=TIMEOUT)
        if res.status_code == 200:
            return res.json()["url"]
    except requests.RequestException as e:
        print(f"discovery of {name} failed: {e}")
    return None


def run_service(app, name, default_port):
    port = int(os.environ.get("PORT", default_port))
    host = os.environ.get("HOST", "localhost")
    url = f"http://{host}:{port}"
    location = location_from_env()
    instance = os.environ.get("INSTANCE", str(port))
    meta = {"service": name, "instance_id": make_service_id(name, location, instance),
            "url": url, "location": location, "started_at": time.time()}
    stats = {"requests": 0, "errors": 0, "total_ms": 0.0, "last_request_at": None, "endpoints": {}}
    stats_lock = threading.Lock()
    monitoring_paths = ("/health", "/metrics")

    @app.before_request
    def _start_timer():
        g.t0 = time.perf_counter()

    @app.after_request
    def _record(resp):
        # Allow the dashboard (served by the registry on another port) to call us
        resp.headers["Access-Control-Allow-Origin"] = "*"
        if request.path not in monitoring_paths and "t0" in g:
            ms = (time.perf_counter() - g.t0) * 1000
            key = f"{request.method} {request.url_rule.rule if request.url_rule else request.path}"
            with stats_lock:
                stats["requests"] += 1
                stats["errors"] += resp.status_code >= 400
                stats["total_ms"] += ms
                stats["last_request_at"] = time.time()
                stats["endpoints"][key] = stats["endpoints"].get(key, 0) + 1
        return resp

    @app.route("/health", methods=["GET"])
    def health():
        return {"status": "up", "service": name, "instance_id": meta["instance_id"]}, 200

    @app.route("/metrics", methods=["GET"])
    def metrics():
        with stats_lock:
            s = dict(stats, endpoints=dict(stats["endpoints"]))
        avg = s.pop("total_ms") / s["requests"] if s["requests"] else None
        return {**meta, **s, "uptime_s": round(time.time() - meta["started_at"], 1),
                "avg_latency_ms": round(avg, 2) if avg is not None else None}, 200

    # Retry until the registry is reachable
    while True:
        try:
            instance_id = meta["instance_id"] = register(name, url, location, instance)
            break
        except requests.RequestException as e:
            print(f"[{name}] registry not reachable ({e}), retrying...")
            time.sleep(2)

    print(f"[{name}] registered as {instance_id} at {url}")
    start_heartbeat(name, url, location, instance, instance_id)
    atexit.register(unregister, name, instance_id)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))  # make atexit run on kill
    app.run(host=host, port=port, threaded=True)
