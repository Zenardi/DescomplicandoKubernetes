"""
TipsBank — Auditoria
Recebe eventos de transacoes e grava arquivos jsonl em /data (PV NFS em producao).
Tambem expoe os eventos por consulta read-only para o time de auditoria/BACEN.
"""
import os
import json
import logging
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field
from prometheus_client import Counter, Gauge, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","service":"auditoria","msg":"%(message)s"}',
)
log = logging.getLogger("auditoria")

DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

eventos_total = Counter("auditoria_eventos_total", "Eventos recebidos", ["tipo"])
arquivo_bytes = Gauge("auditoria_arquivo_bytes", "Bytes totais dos arquivos de auditoria")


class Evento(BaseModel):
    tipo: str = Field(min_length=3)
    transacao_id: str | None = None
    origem_id: str | None = None
    destino_id: str | None = None
    valor: str | None = None
    versao_app: str | None = None


app = FastAPI(title="TipsBank — Auditoria")


def _arquivo_do_dia() -> Path:
    dia = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return DATA_DIR / f"eventos-{dia}.jsonl"


@app.get("/health/live")
def live():
    return {"status": "ok"}


@app.get("/health/ready")
def ready():
    if not DATA_DIR.exists() or not os.access(DATA_DIR, os.W_OK):
        raise HTTPException(status_code=503, detail="DATA_DIR nao gravavel")
    return {"status": "ready"}


@app.get("/health/startup")
def startup():
    return {"status": "started", "data_dir": str(DATA_DIR)}


@app.get("/metrics")
def metrics():
    total = 0
    for p in DATA_DIR.glob("eventos-*.jsonl"):
        try:
            total += p.stat().st_size
        except FileNotFoundError:
            pass
    arquivo_bytes.set(total)
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/eventos", status_code=201)
def receber(evento: Evento):
    registro = {
        "id": str(uuid.uuid4()),
        "recebido_em": datetime.now(timezone.utc).isoformat(),
        **evento.model_dump(),
    }
    try:
        with _arquivo_do_dia().open("a") as f:
            f.write(json.dumps(registro, ensure_ascii=False) + "\n")
    except OSError as e:
        log.error(f"falha gravando evento: {e}")
        raise HTTPException(status_code=500, detail="falha ao persistir evento")
    eventos_total.labels(evento.tipo).inc()
    log.info(f"evento registrado id={registro['id']} tipo={evento.tipo}")
    return registro


@app.get("/eventos")
def listar(dia: str | None = None, limit: int = 100):
    alvo = DATA_DIR / f"eventos-{dia}.jsonl" if dia else _arquivo_do_dia()
    if not alvo.exists():
        return []
    linhas = alvo.read_text().splitlines()[-min(limit, 500):]
    return [json.loads(l) for l in linhas if l.strip()]


@app.get("/arquivos")
def arquivos():
    return sorted([p.name for p in DATA_DIR.glob("eventos-*.jsonl")])
