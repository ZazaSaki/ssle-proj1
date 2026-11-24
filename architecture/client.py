# Legitimate client (Guide 3, step 3): continuously asks the analytics service
# ("temperature detector") for anomalies and logs how long each answer took.
import os
import time

import requests

REGISTRY_URL = os.environ.get("REGISTRY_URL", "http://localhost:5050")
INTERVAL = float(os.environ.get("INTERVAL", 3))

while True:
    try:
        d = requests.get(f"{REGISTRY_URL}/discover/analytics-service", timeout=3)
        if d.status_code != 200:
            print(f"{time.strftime('%T')} no analytics-service instance available", flush=True)
            time.sleep(INTERVAL)
            continue
        url = d.json()["url"]
        t0 = time.perf_counter()
        r = requests.get(f"{url}/anomalies", timeout=5)
        ms = (time.perf_counter() - t0) * 1000
        print(f"{time.strftime('%T')} /anomalies -> {r.status_code} in {ms:.0f} ms, "
              f"{len(r.json().get('anomalies', []))} anomalies", flush=True)
    except (requests.RequestException, KeyError, ValueError) as e:
        print(f"{time.strftime('%T')} error: {e}", flush=True)
    time.sleep(INTERVAL)
