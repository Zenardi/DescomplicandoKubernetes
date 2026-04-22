"""
Locust - stress test do TipsBank.
Simula usuarios criando contas e fazendo transferencias.

Execucao local:
    locust -f locustfile.py --host http://localhost:8082

Execucao em Kubernetes (como Job/Deployment, ver MANUAL-ALUNO semana 3):
    env LOCUST_HOST=http://api-transacoes.tipsbank.svc.cluster.local:8080 locust --headless -u 200 -r 20 -t 5m
"""
import random
import uuid
from decimal import Decimal
from locust import HttpUser, task, between, events


CONTAS_CRIADAS: list[str] = []


class UsuarioBanco(HttpUser):
    wait_time = between(0.5, 2)

    def on_start(self):
        """Cria uma conta por usuario para termos saldo disponivel."""
        documento = "".join(random.choices("0123456789", k=11))
        payload = {
            "titular": f"Aluno {uuid.uuid4().hex[:6]}",
            "documento": documento,
            "saldo_inicial": "10000.00",
        }
        r = self.client.post(
            "/contas",
            json=payload,
            name="/contas (setup)",
            catch_response=True,
        )
        if r.status_code == 201:
            CONTAS_CRIADAS.append(r.json()["id"])
            r.success()
        else:
            r.failure(f"falha criando conta: {r.status_code}")

    @task(3)
    def transferir(self):
        if len(CONTAS_CRIADAS) < 2:
            return
        origem, destino = random.sample(CONTAS_CRIADAS, 2)
        valor = round(random.uniform(1, 50), 2)
        self.client.post(
            "/transferencias",
            json={"origem_id": origem, "destino_id": destino, "valor": str(valor)},
            name="/transferencias",
        )

    @task(1)
    def consultar_extrato(self):
        if not CONTAS_CRIADAS:
            return
        conta = random.choice(CONTAS_CRIADAS)
        self.client.get(f"/extrato/{conta}", name="/extrato/:id")


@events.test_stop.add_listener
def resumo(environment, **_):
    print(f"\nContas criadas durante o teste: {len(CONTAS_CRIADAS)}")
