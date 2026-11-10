from flask import Flask, jsonify
import psutil
import json
from datetime import datetime, timezone

app = Flask(__name__)

STATUS_FILE = "/runtime/status.json"


def get_temperature():
    try:
        with open(
            "/sys/class/thermal/thermal_zone0/temp",
            "r"
        ) as file:
            return round(
                int(file.read().strip()) / 1000,
                1
            )
    except (FileNotFoundError, ValueError):
        return None


def get_disk(path):
    try:
        usage = psutil.disk_usage(path)

        return {
            "total": usage.total,
            "used": usage.used,
            "free": usage.free,
            "percent": usage.percent
        }

    except (FileNotFoundError, PermissionError):
        return None


def get_docker_status():
    try:
        with open(STATUS_FILE, "r") as file:
            data = json.load(file)

        return data.get("docker", {})

    except (FileNotFoundError, json.JSONDecodeError):
        return {}


@app.get("/api/status")
def status():

    memory = psutil.virtual_memory()

    return jsonify({
        "timestamp": datetime.now(
            timezone.utc
        ).isoformat(),

        "system": {
            "cpu_percent": psutil.cpu_percent(
                interval=0.2
            ),

            "memory_percent": memory.percent,

            "memory_used": memory.used,

            "memory_total": memory.total,

            "temperature": get_temperature(),

            "uptime": int(
                datetime.now().timestamp()
                - psutil.boot_time()
            )
        },

        "disk": {
            "root": get_disk("/host"),
            "external_drive": get_disk("/mnt/external_drive")
        },

        "docker": get_docker_status()
    })


@app.get("/api/health")
def health():
    return jsonify({
        "status": "ok"
    })
