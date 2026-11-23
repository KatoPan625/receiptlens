FROM python:3.13.18-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 EVENTS_ENABLED=true
# Pick up Debian security fixes released after the base image was built (Trivy in CI checks this).
RUN apt-get update && apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/*

WORKDIR /srv
COPY requirements.txt .
# pip is only needed to build the image; removing it also removes its vendored libraries
# (urllib3, msgpack, ...) that Trivy reports as vulnerable.
RUN pip install --no-cache-dir -r requirements.txt \
 && pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3.13/ensurepip
COPY alembic.ini .
COPY migrations ./migrations
COPY app ./app

# Run as an unprivileged user
RUN useradd --uid 10001 --no-create-home appuser
USER 10001

EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--root-path", "/api", "--proxy-headers", "--forwarded-allow-ips", "*"]
