# Analytics Service: reads data through the storage service (never the DB directly)
import statistics

import requests
from flask import Flask, jsonify, request

from common import discover, run_service

app = Flask(__name__)
SERVICE_NAME = "analytics-service"


def fetch_readings(device_id=None, limit=1000):
    storage = discover("storage-service")
    if not storage:
        raise RuntimeError("storage unavailable")
    params = {"limit": limit}
    if device_id:
        params["device_id"] = device_id
    res = requests.get(f"{storage}/readings", params=params, timeout=3)
    res.raise_for_status()
    return res.json()


def summary(values):
    if not values:
        return {"count": 0, "min": None, "max": None, "average": None, "stdev": None}
    return {
        "count": len(values),
        "min": min(values),
        "max": max(values),
        "average": round(statistics.mean(values), 2),
        "stdev": round(statistics.pstdev(values), 2),
    }


@app.errorhandler(RuntimeError)
@app.errorhandler(requests.RequestException)
def upstream_error(e):
    return jsonify({"error": str(e)}), 503


@app.route("/average", methods=["GET"])
def average():
    values = [r["temperature"] for r in fetch_readings(request.args.get("device_id"))]
    avg = round(statistics.mean(values), 2) if values else None
    return jsonify({"average_temperature": avg})


@app.route("/stats", methods=["GET"])
def stats():
    rows = fetch_readings(request.args.get("device_id"))
    per_device = {}
    for r in rows:
        per_device.setdefault(r["device_id"], []).append(r["temperature"])
    return jsonify({
        "overall": summary([r["temperature"] for r in rows]),
        "per_device": {d: summary(v) for d, v in per_device.items()},
    })


@app.route("/anomalies", methods=["GET"])
def anomalies():
    k = request.args.get("k", 2.0, type=float)
    rows = fetch_readings(request.args.get("device_id"))
    values = [r["temperature"] for r in rows]
    if len(values) < 2:
        return jsonify({"anomalies": [], "threshold_sigma": k})
    mean, sd = statistics.mean(values), statistics.pstdev(values)
    out = [r for r in rows if sd and abs(r["temperature"] - mean) > k * sd]
    return jsonify({"mean": round(mean, 2), "stdev": round(sd, 2), "threshold_sigma": k, "anomalies": out})


if __name__ == "__main__":
    run_service(app, SERVICE_NAME, 5003)
