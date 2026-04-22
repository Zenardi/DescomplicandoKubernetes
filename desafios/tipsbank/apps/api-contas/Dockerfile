# syntax=docker/dockerfile:1.7

# =============================================================================
# STAGE 1 — builder (Chainguard Python dev — mesma versão do runtime)
# =============================================================================
FROM cgr.dev/chainguard/python:latest-dev AS builder

USER root
WORKDIR /app

COPY requirements.txt .
RUN pip3 install --no-cache-dir --target=/packages -r requirements.txt

COPY main.py .

# =============================================================================
# STAGE 2 — runtime (Chainguard Distroless Python, sem shell, sem package manager)
# cgr.dev/chainguard/python → Python 3 + glibc, user nonroot (uid 65532)
# =============================================================================
FROM cgr.dev/chainguard/python:latest

WORKDIR /app

COPY --from=builder /packages /packages
COPY --from=builder /app/main.py /app/main.py

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/packages \
    PATH=/packages/bin:$PATH

EXPOSE 8080

ENTRYPOINT ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
