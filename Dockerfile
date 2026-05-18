FROM python:3.12-slim AS builder

LABEL name="httpbin"
LABEL version="0.9.2"
LABEL description="A simple HTTP service."
LABEL org.kennethreitz.vendor="Kenneth Reitz"

ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends gcc libffi-dev && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN python -m venv /opt/venv && /opt/venv/bin/pip install --upgrade pip && /opt/venv/bin/pip install --require-hashes -r requirements.txt

FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 
ENV PYTHONUNBUFFERED=1 
ENV PATH="/opt/venv/bin:$PATH" 
ENV GUNICORN_CMD_ARGS="--worker-tmp-dir /tmp"

RUN groupadd --gid 1000 appgroup && useradd --uid 1000 --gid appgroup --no-create-home --shell /sbin/nologin appuser

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --chown=appuser:appgroup . .

USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 
CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/get')" || exit 1

CMD ["gunicorn", "--workers", "4", "--bind", "0.0.0.0:8080", "--access-logfile", "-", "--error-logfile", "-", "--timeout", "60", "httpbin:app"]



# Should elaborate on this one



RUN apt update -y && apt install python3-pip git -y && pip3 install --no-cache-dir pipenv

ADD Pipfile Pipfile.lock /httpbin/
WORKDIR /httpbin
RUN /bin/bash -c "pip3 install --no-cache-dir -r <(pipenv lock -r)"

ADD . /httpbin
RUN pip3 install --no-cache-dir /httpbin

EXPOSE 80

CMD ["gunicorn", "-b", "0.0.0.0:80", "httpbin:app", "-k", "gevent"]
