# Ingestion Service: entry point for sensor data -> validate, normalise, route to storage
import os
from datetime import datetime, timezone

import requests
from flask import Flask, jsonify, request

from common import discover, location_from_env, run_service

app = Flask(__name__)
SERVICE_NAME = "ingestion-service"

# Optional per-IDENTITY rate limit (keyed on device_id, not source IP). OFF by default
# so the baseline is unchanged; enabled with RATELIMIT=identity (see architecture/ratelimit.py).
_RL_MODE = os.environ.get("RATELIMIT", "off")
_rl = None
if _RL_MODE == "identity":
    from ratelimit import TokenBucketSet
    _rl = TokenBucketSet(rate=float(os.environ.get("RL_RATE", "5")),
                         burst=float(os.environ.get("RL_BURST", "10")))


def normalise(data):
    device_id = data.get("device_id")
    if not isinstance(device_id, str) or not device_id:
        raise ValueError("missing device_id")
    try:
        temp = float(data.get("temperature"))
    except (TypeError, ValueError):
        raise ValueError("temperature must be numeric")
    unit = str(data.get("unit", "C")).upper()
    if unit == "F":
        temp = (temp - 32) * 5 / 9
    elif unit == "K":
        temp = temp - 273.15
    elif unit != "C":
        raise ValueError(f"unknown unit {unit}")
    if not -100 <= temp <= 150:
        raise ValueError("temperature out of physical range")
    return {
        "device_id": device_id,
        "temperature": round(temp, 2),
        "received_at": datetime.now(timezone.utc).isoformat(),
    }


@app.route("/ingest", methods=["POST"])
def ingest():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "expected JSON object"}), 400
    if _rl is not None:
        device_id = data.get("device_id")
        if device_id and not _rl.allow(device_id):
            return jsonify({"error": "rate limit exceeded for this identity"}), 429
    try:
        reading = normalise(data)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    # Discover storage on every request -> registry load-balances between instances,
    # preferring ones in the same datacenter (country.region.dc prefix)
    same_dc = ".".join(location_from_env().split(".")[:3])
    storage = discover("storage-service", near=same_dc)
    if not storage:
        return jsonify({"error": "storage unavailable"}), 503
    try:
        res = requests.post(f"{storage}/store", json=reading, timeout=3)
        print("Stored:", reading, "via", storage)
        return jsonify({"stored": res.ok, "storage": storage}), res.status_code
    except requests.RequestException as e:
        return jsonify({"error": f"storage error: {e}"}), 502


if __name__ == "__main__":
    run_service(app, SERVICE_NAME, 5001)
