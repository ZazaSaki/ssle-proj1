# Temperature (Celsius) sensor: finds the ingestion service through the registry
import os
import random
import time

import requests

from common import discover, location_from_env, make_service_id

LOCATION = location_from_env()
DEVICE_ID = make_service_id("temp-sensor", LOCATION, os.environ.get("INSTANCE", "001"))
INTERVAL = float(os.environ.get("INTERVAL", 5))


def send_temp():
    backoff = 1
    while True:
        ingestion = discover("ingestion-service", near=LOCATION)
        if not ingestion:
            print(f"ingestion not found, retrying in {backoff}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 30)
            continue
        backoff = 1
        temp = round(random.uniform(20.0, 30.0), 2)
        if random.random() < 0.05:  # occasional spike so /anomalies has something to show
            temp = round(random.uniform(40.0, 50.0), 2)
        payload = {"device_id": DEVICE_ID, "temperature": temp, "unit": "C"}
        try:
            res = requests.post(f"{ingestion}/ingest", json=payload, timeout=3)
            print("Sent:", payload, "->", res.status_code, res.json())
        except requests.RequestException as e:
            print("Error:", e)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    send_temp()
