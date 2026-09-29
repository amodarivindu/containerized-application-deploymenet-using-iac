"""Calculator web application deployed to AWS ECS Fargate."""

import os
import socket
from datetime import datetime, timezone

from flask import Flask, jsonify, render_template, request

from calculator import CalculationError, evaluate

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "dev")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")
STARTED_AT = datetime.now(timezone.utc).isoformat()


def _info() -> dict:
    return {
        "version": APP_VERSION,
        "environment": ENVIRONMENT,
        "hostname": socket.gethostname(),
        "started": STARTED_AT,
    }


@app.get("/")
def index():
    return render_template("index.html", **_info())


@app.post("/api/calculate")
def calculate():
    payload = request.get_json(silent=True) or {}
    expression = payload.get("expression")
    try:
        result = evaluate(expression)
    except CalculationError as exc:
        return jsonify(expression=expression, error=str(exc)), 400
    return jsonify(expression=expression, result=result, hostname=socket.gethostname())


@app.get("/api/info")
def info():
    return jsonify(_info())


@app.get("/health")
def health():
    # Used by the ALB target group and the ECS container health check.
    return jsonify(status="ok"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
