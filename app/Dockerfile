# syntax=docker/dockerfile:1

# ---------- base: runtime dependencies ----------
FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

# ---------- test: runs the unit tests during the build ----------
# Jenkins runs `docker build --target test` - the build fails if tests fail.
FROM base AS test
COPY requirements-dev.txt .
RUN pip install -r requirements-dev.txt
COPY src/ ./src/
COPY tests/ ./tests/
RUN python -m pytest -q tests

# ---------- runtime: the image pushed to ECR ----------
FROM base AS runtime
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PORT=8080 \
    WEB_CONCURRENCY=2
RUN useradd --create-home --uid 10001 appuser
COPY --chown=appuser:appuser src/ ./src/
USER appuser
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health', timeout=3)" || exit 1

# gunicorn binds to 0.0.0.0:$PORT and reads worker count from $WEB_CONCURRENCY,
# which the ECS task definition sets based on the task's vCPU allocation.
CMD ["gunicorn", "--chdir", "src", "--threads", "4", "--worker-tmp-dir", "/dev/shm", \
     "--access-logfile", "-", "app:app"]
