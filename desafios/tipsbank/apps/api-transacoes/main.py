"""
TipsBank — API de Transacoes
Transferencias entre contas. Chama api-contas e publica eventos em auditoria.
"""
import os
import logging
import time
import uuid
from contextlib import asynccontextmanager
from decimal import Decimal

import httpx
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field
from sqlalchemy import Column, String, Numeric, DateTime, create_engine, func
from sqlalchemy.orm import declarative_base, sessionmaker, Session
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","service":"api-transacoes","msg":"%(message)s"}',
)
log = logging.getLogger("api-transacoes")

DB_URL = os.getenv(
    "DB_URL",
    "postgresql+psycopg://tipsbank:tipsbank@postgres:5432/tipsbank",
)
CONTAS_URL = os.getenv("CONTAS_URL", "http://api-contas:8080")
AUDITORIA_URL = os.getenv("AUDITORIA_URL", "http://auditoria:8080")
APP_VERSION = os.getenv("APP_VERSION", "v1")

engine = create_engine(DB_URL, pool_pre_ping=True, pool_size=5, max_overflow=10)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False)
Base = declarative_base()


class Transacao(Base):
    __tablename__ = "transacoes"
    id = Column(String, primary_key=True)
    origem_id = Column(String, nullable=False, index=True)
    destino_id = Column(String, nullable=False, index=True)
    valor = Column(Numeric(15, 2), nullable=False)
    status = Column(String, nullable=False)
    criada_em = Column(DateTime, server_default=func.now())


class TransferenciaIn(BaseModel):
    origem_id: str
    destino_id: str
    valor: Decimal = Field(gt=0)


class TransacaoOut(BaseModel):
    id: str
    origem_id: str
    destino_id: str
    valor: Decimal
    status: str

    class Config:
        from_attributes = True


req_counter = Counter("http_requests_total", "Total de requisições HTTP", ["method", "path", "status"])
req_latency = Histogram("http_request_duration_seconds", "Latência", ["path"])
tx_counter = Counter("transacoes_total", "Transacoes executadas", ["status"])


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info(f"bootstrap versao={APP_VERSION}")
    Base.metadata.create_all(engine)
    yield


app = FastAPI(title="TipsBank — Transacoes", lifespan=lifespan)


@app.middleware("http")
async def obs(request, call_next):
    start = time.time()
    resp = await call_next(request)
    req_counter.labels(request.method, request.url.path, resp.status_code).inc()
    req_latency.labels(request.url.path).observe(time.time() - start)
    resp.headers["X-App-Version"] = APP_VERSION
    return resp


def db() -> Session:
    return SessionLocal()


@app.get("/health/live")
def live():
    return {"status": "ok", "version": APP_VERSION}


@app.get("/health/ready")
def ready():
    try:
        s = SessionLocal()
        s.execute(func.now().select()).scalar()
        s.close()
        return {"status": "ready"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@app.get("/health/startup")
def startup():
    return {"status": "started"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/transferencias", response_model=TransacaoOut, status_code=201)
def transferir(payload: TransferenciaIn):
    tx_id = str(uuid.uuid4())
    s = db()
    try:
        log.info(f"transferencia id={tx_id} origem={payload.origem_id} destino={payload.destino_id} valor={payload.valor}")
        with httpx.Client(timeout=5.0) as client:
            r = client.post(
                f"{CONTAS_URL}/contas/{payload.origem_id}/saldo",
                json={"valor": str(payload.valor), "operacao": "debito"},
            )
            if r.status_code != 200:
                tx_counter.labels("falha_debito").inc()
                raise HTTPException(status_code=r.status_code, detail=f"debito falhou: {r.text}")

            r2 = client.post(
                f"{CONTAS_URL}/contas/{payload.destino_id}/saldo",
                json={"valor": str(payload.valor), "operacao": "credito"},
            )
            if r2.status_code != 200:
                client.post(
                    f"{CONTAS_URL}/contas/{payload.origem_id}/saldo",
                    json={"valor": str(payload.valor), "operacao": "credito"},
                )
                tx_counter.labels("falha_credito").inc()
                raise HTTPException(status_code=r2.status_code, detail=f"credito falhou: {r2.text}")

        tx = Transacao(
            id=tx_id,
            origem_id=payload.origem_id,
            destino_id=payload.destino_id,
            valor=payload.valor,
            status="concluida",
        )
        s.add(tx)
        s.commit()
        s.refresh(tx)

        try:
            with httpx.Client(timeout=3.0) as client:
                client.post(
                    f"{AUDITORIA_URL}/eventos",
                    json={
                        "tipo": "transferencia",
                        "transacao_id": tx.id,
                        "origem_id": tx.origem_id,
                        "destino_id": tx.destino_id,
                        "valor": str(tx.valor),
                        "versao_app": APP_VERSION,
                    },
                )
        except Exception as e:
            log.warning(f"auditoria indisponivel: {e}")

        tx_counter.labels("ok").inc()
        return tx
    finally:
        s.close()


@app.get("/transferencias/{tx_id}", response_model=TransacaoOut)
def obter(tx_id: str):
    s = db()
    try:
        tx = s.query(Transacao).get(tx_id)
        if not tx:
            raise HTTPException(status_code=404, detail="nao encontrada")
        return tx
    finally:
        s.close()


@app.get("/extrato/{conta_id}", response_model=list[TransacaoOut])
def extrato(conta_id: str, limit: int = 20):
    s = db()
    try:
        from sqlalchemy import or_
        q = (
            s.query(Transacao)
            .filter(or_(Transacao.origem_id == conta_id, Transacao.destino_id == conta_id))
            .order_by(Transacao.criada_em.desc())
            .limit(min(limit, 100))
        )
        return q.all()
    finally:
        s.close()
