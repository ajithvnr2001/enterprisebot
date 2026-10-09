# --- Builder stage: prepare application files ---
FROM python:3.12.7-slim-bookworm AS builder
WORKDIR /app
# No third-party dependencies (stdlib only), but keep the layer for clarity.
COPY app.py ./
RUN python3 -m py_compile app.py && ls -l /app

# --- Runtime stage: minimal, non-root ---
FROM python:3.12.7-slim-bookworm
WORKDIR /app

# Create a dedicated non-root user (UID 10001, no shell, no home write).
RUN groupadd -r appgroup --gid 10001 \
 && useradd -r -g appgroup --uid 10001 --create-home --home-dir /home/appuser --shell /usr/sbin/nologin appuser \
 && chown -R appuser:appgroup /app

COPY --from=builder --chown=appuser:appgroup /app/app.py ./

ENV APP_NAME=demo \
    VERSION=0.1.0 \
    PORT=8080

EXPOSE 8080
USER appuser
CMD ["python3", "app.py"]
