FROM python:3.13.18-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    HOME=/opt/ocr \
    PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
# OpenCV (pulled in by PaddleOCR) needs these shared libraries; upgrade picks up Debian security fixes.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get install -y --no-install-recommends libgomp1 libgl1 libglib2.0-0 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /srv
COPY requirements.txt .
# pip is only needed at build time; removing it drops its vendored libraries that Trivy flags.
RUN pip install --no-cache-dir -r requirements.txt \
 && pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3.13/ensurepip

RUN useradd --uid 10002 --home-dir /opt/ocr --create-home ocr
USER 10002
COPY --chown=10002 receipt_parser.py worker.py ./
# Download the models NOW: at runtime the worker sits on an internal network with no Internet.
RUN python -c "import worker; worker.make_ocr()" && ls /opt/ocr/.paddlex/official_models

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD python -c "import os,sys,time; sys.exit(time.time() - os.path.getmtime('/tmp/heartbeat') > 90)"
CMD ["python", "worker.py"]
