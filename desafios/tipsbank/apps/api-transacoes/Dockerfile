# syntax=docker/dockerfile:1.7

FROM cgr.dev/chainguard/python:latest-dev AS builder

USER root
WORKDIR /app

COPY requirements.txt .
RUN pip3 install --no-cache-dir --target=/packages -r requirements.txt

COPY main.py .

FROM cgr.dev/chainguard/python:latest

WORKDIR /app

COPY --from=builder /packages /packages
COPY --from=builder /app/main.py /app/main.py

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/packages \
    PATH=/packages/bin:$PATH \
    APP_VERSION=v1

EXPOSE 8080

ENTRYPOINT ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
