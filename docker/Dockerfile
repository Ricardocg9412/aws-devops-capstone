ARG PYTHON_IMAGE=python:3.14-slim

FROM ${PYTHON_IMAGE} AS builder

WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

FROM ${PYTHON_IMAGE} AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UVICORN_HOST=0.0.0.0 \
    UVICORN_PORT=8080 \
    PATH="/opt/venv/bin:$PATH"

WORKDIR /app
RUN useradd --create-home --uid 10001 inventory

COPY --from=builder /opt/venv /opt/venv

COPY --chown=inventory:inventory app/ ./app/
USER inventory

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:' + os.getenv('UVICORN_PORT', '8000') + '/health', timeout=2)"

CMD ["uvicorn", "app.main:app", "--workers", "1", "--no-access-log"]
