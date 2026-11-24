# Storage Service: the only component that touches the database
import os
import sqlite3
from contextlib import contextmanager

from flask import Flask, jsonify, request

from common import run_service

app = Flask(__name__)
SERVICE_NAME = "storage-service"
DB = os.environ.get("DB_PATH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "temp_data.db"))


@contextmanager
def connect():
    # sqlite3's own context manager only commits; close the connection too
    conn = sqlite3.connect(DB, timeout=5)
    try:
        with conn:
            yield conn
    finally:
        conn.close()


def init_db():
    with connect() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS temperatures (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                device_id TEXT NOT NULL,
                temperature REAL NOT NULL,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                stored_by TEXT
            )
        """)


@app.route("/store", methods=["POST"])
def store():
    data = request.get_json(silent=True) or {}
    device_id = data.get("device_id")
    temperature = data.get("temperature")
    if not isinstance(device_id, str) or not device_id:
        return jsonify({"error": "invalid device_id"}), 400
    if isinstance(temperature, bool) or not isinstance(temperature, (int, float)):
        return jsonify({"error": "invalid temperature"}), 400
    with connect() as conn:  # parameterised query -> no SQL injection
        conn.execute("INSERT INTO temperatures (device_id, temperature, stored_by) VALUES (?, ?, ?)",
                     (device_id, float(temperature), request.host))
    return jsonify({"status": "stored", "by": request.host}), 200


@app.route("/readings", methods=["GET"])
def readings():
    device_id = request.args.get("device_id")
    limit = min(request.args.get("limit", 1000, type=int), 10000)
    query = "SELECT device_id, temperature, timestamp FROM temperatures"
    args = []
    if device_id:
        query += " WHERE device_id = ?"
        args.append(device_id)
    query += " ORDER BY id DESC LIMIT ?"
    args.append(limit)
    with connect() as conn:
        rows = conn.execute(query, args).fetchall()
    return jsonify([{"device_id": d, "temperature": t, "timestamp": ts} for d, t, ts in rows])


if __name__ == "__main__":
    init_db()
    run_service(app, SERVICE_NAME, 5002)
