# Prometheus exporter for the Guide 1 SOA (Guide 3, step 4 + 5)
#
# - Liveness: asks the registry which instances exist and probes each /health
# - Application metrics: reads each instance's /metrics (requests, errors, latency)
#
# Exposes everything on :8000/metrics for Prometheus to scrape.
import os
import time

import requests
from prometheus_client import Counter, Gauge, start_http_server

REGISTRY_URL = os.environ.get("REGISTRY_URL", "http://localhost:5050")
INTERVAL = float(os.environ.get("INTERVAL", 5))
TIMEOUT = 2

L = ["service", "service_id"]
health = Gauge("service_health", "1 if the instance answers /health with 200, else 0", L)
health_latency = Gauge("service_health_latency_seconds", "Latency of the /health probe", L)
requests_total = Gauge("service_requests_total", "Requests served (from the service's own /metrics)", L)
errors_total = Gauge("service_errors_total", "Requests answered with status >= 400", L)
avg_latency = Gauge("service_avg_latency_seconds", "Average request latency reported by the service", L)
uptime = Gauge("service_uptime_seconds", "Uptime reported by the service", L)
registry_up = Gauge("registry_up", "1 if the service registry answers")
registered = Gauge("registry_instances", "Instances currently registered per service", ["service"])
probe_failures = Counter("exporter_probe_failures_total", "Failed probes", L)
in_registry = Gauge("service_registered", "1 if the instance is currently in the registry", L)

# Every instance ever seen: (service, instance_id) -> url.
# The registry evicts dead instances, so without this a crashed service would
# simply disappear from the metrics instead of showing service_health == 0.
known = {}


def check():
    try:
        services = requests.get(f"{REGISTRY_URL}/services", timeout=TIMEOUT).json()
        registry_up.set(1)
    except requests.RequestException:
        registry_up.set(0)
        services = {}
    current = set()
    for name, instances in services.items():
        registered.labels(service=name).set(len(instances))
        for inst in instances:
            known[(name, inst["instance_id"])] = inst["url"]
            current.add((name, inst["instance_id"]))
    for name in {n for n, _ in known} - set(services):
        registered.labels(service=name).set(0)

    for (name, instance_id), url in known.items():
        lbl = dict(service=name, service_id=instance_id)
        in_registry.labels(**lbl).set(1 if (name, instance_id) in current else 0)
        t0 = time.perf_counter()
        try:
            ok = requests.get(f"{url}/health", timeout=TIMEOUT).status_code == 200
        except requests.RequestException:
            ok = False
        health_latency.labels(**lbl).set(time.perf_counter() - t0)
        health.labels(**lbl).set(1 if ok else 0)
        if not ok:
            probe_failures.labels(**lbl).inc()
            continue
        try:
            m = requests.get(f"{url}/metrics", timeout=TIMEOUT).json()
        except (requests.RequestException, ValueError):
            continue
        requests_total.labels(**lbl).set(m.get("requests", 0))
        errors_total.labels(**lbl).set(m.get("errors", 0))
        uptime.labels(**lbl).set(m.get("uptime_s", 0))
        if m.get("avg_latency_ms") is not None:
            avg_latency.labels(**lbl).set(m["avg_latency_ms"] / 1000)


if __name__ == "__main__":
    start_http_server(int(os.environ.get("EXPORTER_PORT", 8000)), addr="0.0.0.0")
    print("exporter on :8000/metrics")
    while True:
        check()
        time.sleep(INTERVAL)
