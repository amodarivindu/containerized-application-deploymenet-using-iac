"""Sample web application deployed to AWS ECS Fargate."""

import os
import socket
from datetime import datetime, timezone

from flask import Flask, jsonify

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "dev")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")
STARTED_AT = datetime.now(timezone.utc).isoformat()

PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ECS Fargate Demo</title>
  <style>
    body {{ font-family: system-ui, sans-serif; background: #0f172a; color: #e2e8f0;
           display: grid; place-items: center; min-height: 100vh; margin: 0; }}
    .card {{ background: #1e293b; padding: 2rem 3rem; border-radius: 12px; }}
    h1 {{ margin-top: 0; color: #38bdf8; }}
    dt {{ color: #94a3b8; font-size: .85rem; }}
    dd {{ margin: 0 0 1rem; font-family: ui-monospace, monospace; }}
  </style>
</head>
<body>
  <div class="card">
    <h1>Hello from AWS ECS Fargate</h1>
    <dl>
      <dt>Version</dt><dd>{version}</dd>
      <dt>Environment</dt><dd>{environment}</dd>
      <dt>Served by task</dt><dd>{hostname}</dd>
      <dt>Task started</dt><dd>{started}</dd>
    </dl>
  </div>
</body>
</html>"""


def _info() -> dict:
    return {
        "version": APP_VERSION,
        "environment": ENVIRONMENT,
        "hostname": socket.gethostname(),
        "started": STARTED_AT,
    }


@app.get("/")
def index():
    return PAGE.format(**_info())


@app.get("/api/info")
def info():
    return jsonify(_info())


@app.get("/health")
def health():
    # Used by the ALB target group and the ECS container health check.
    return jsonify(status="ok"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
