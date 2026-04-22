# TipsBank — Desafio Final DK8s 2025

> **Banco digital fictício** usado como desafio final da turma 2025 do treinamento **Descomplicando Kubernetes** da LinuxTips.
> **Início: 21/04/2026** · **Entrega: 21/05/2026** · Nível: **Hard** · Escopo: **Days 1 a 19 do DK8s**

---

## O desafio em uma frase

> Receba uma aplicação bancária em microsserviços e a entregue rodando em Kubernetes (kubeadm **e** EKS) com **compliance de banco** — imagens assinadas, zero-trust de rede, RBAC por perfil, políticas Kyverno, observabilidade completa, autoscaling e tudo empacotado num Helm Chart.

Se o aluno completou os 19 Days do DK8s, tem 100% das ferramentas para fazer. Se ainda tem dúvida em algum Day, **este é o momento de voltar**.

---

## O que tem nesse repositório

```
tipsbank/
├── README.md                    <- você está aqui
├── docker-compose.yml           <- roda tudo local antes de ir pro K8s
├── apps/
│   ├── api-contas/              <- FastAPI + Postgres (CRUD de contas + login com bcrypt)
│   ├── api-transacoes/          <- FastAPI + Postgres (transferências)
│   ├── auditoria/               <- FastAPI + arquivo em /data (NFS)
│   └── web/                     <- SPA (nginx-unprivileged + HTML/JS vanilla + proxy reverso)
├── sql/
│   └── init.sql                 <- schema + dados seed do Postgres (inclui senha_hash)
├── scripts/
│   └── build-e-assinar.sh       <- referência de build, Trivy e Cosign
├── locust/
│   ├── locustfile.py            <- stress test para a semana 3
│   └── Dockerfile
└── docs/
    ├── ARQUITETURA.md           <- diagrama + mapeamento Day→recurso
    ├── MANUAL-ALUNO.md          <- LEIA ISSO! Passo a passo por semana
    └── MANUAL-INSTRUTOR.md      <- gabarito e armadilhas (não espiar!)
```

---

## Por onde começar

1. **Leia `docs/ARQUITETURA.md`** para entender o alvo.
2. **Leia `docs/MANUAL-ALUNO.md`** — ele te leva da Semana 1 à 4.
3. **Suba a app localmente** para ganhar familiaridade:

```bash
cd tipsbank
docker compose up --build
```

Com isso no ar, a forma mais fácil de brincar é abrir o **frontend**:

- **http://localhost:8080** — SPA completa: landing, abrir conta, login, dashboard, transferir, extrato, auditoria
- Contas seed vêm pré-cadastradas com a senha `giropops` — use `123.456.789-01` como CPF e `giropops` como senha pra entrar como "Jeferson Fernando"

Se preferir bater direto nas APIs:

```bash
# health check
curl http://localhost:8081/health/live   # api-contas
curl http://localhost:8082/health/live   # api-transacoes
curl http://localhost:8083/health/live   # auditoria
curl http://localhost:8080/healthz       # frontend nginx

# listar contas (senha_hash não é exposto)
curl http://localhost:8081/contas | jq

# login (retorna a conta autenticada ou 401)
curl -X POST http://localhost:8081/login \
  -H 'content-type: application/json' \
  -d '{"documento":"12345678901","senha":"giropops"}' | jq

# abrir conta nova (senha é obrigatória)
curl -X POST http://localhost:8081/contas \
  -H 'content-type: application/json' \
  -d '{
    "titular":"Descomplicador",
    "documento":"11122233344",
    "senha":"minhaSenha123",
    "saldo_inicial":"1000.00"
  }' | jq

# fazer uma transferência
curl -X POST http://localhost:8082/transferencias \
  -H 'content-type: application/json' \
  -d '{
    "origem_id":"11111111-1111-1111-1111-111111111111",
    "destino_id":"22222222-2222-2222-2222-222222222222",
    "valor":"100.00"
  }' | jq

# ver evento gravado na auditoria
curl http://localhost:8083/eventos | jq
```

Se isso funciona local, você entendeu o que a app faz. Agora vá pro Kubernetes.

---

## Entregas esperadas (resumo)

| Semana | Foco | Days do DK8s |
|---|---|---|
| 1 | Fundações: cluster, build de imagens, workloads básicos, storage | 1–8, 13 |
| 2 | Exposição e segurança de rede | 9, 10, 17 |
| 3 | Resiliência, scheduling, autoscaling, observabilidade | 4, 11, 12, 14, 16 |
| 4 | Compliance: Kyverno + RBAC + Helm umbrella + entrega final | 15, 18, 19 |

Cada semana tem critérios de aceite explícitos. **Leia o `MANUAL-ALUNO.md`.**

---

## Entregáveis finais do aluno

No fim do mês, o aluno submete um repositório Git público contendo:

1. **Fork deste projeto** com a app (pode modificar se quiser)
2. **Pasta `k8s/`** com todos os manifests YAML organizados (ou só o Helm Chart)
3. **Pasta `helm/tipsbank/`** com o Chart umbrella final
4. **`docs/EVIDENCIAS.md`** com prints, comandos e logs que provam que cada critério de aceite foi atingido
5. **Vídeo de 10-15 min** (link YouTube/Loom) mostrando:
   - `helm install tipsbank` num cluster limpo
   - Locust batendo na API e HPA reagindo
   - Tentativa de aplicar um pod "ruim" sendo bloqueada pelo Kyverno
   - Canary de transações funcionando
   - Grafana mostrando métricas e um alerta disparando

---

## O que NÃO pode ser usado

O desafio é **estritamente** dentro do escopo do DK8s 2025. **Não** use:

- Velero, ArgoCD/Flux, Service Mesh (Istio/Linkerd)
- Operators próprios / CRDs customizados (além dos do kube-prometheus, Kyverno e cert-manager)
- CronJob, Job (exceto o Job opcional do Locust)
- VPA, Cluster Autoscaler, KEDA, Karpenter
- Loki, Falco, External Secrets, Vault

Se usar algo fora dessa lista, a submissão é zerada. O objetivo é **dominar** o conteúdo do treinamento, não buscar atalhos com ferramentas novas.

---

## Suporte durante o mês

- Canal `#desafio-dk8s-2025` no Discord da turma
- Office hours do Jeferson: **quarta, 8h BRT** (ao vivo)
- Rollback didático: se você trava por mais de 48h num passo, peça ajuda. Travar faz parte.

---

**Bom desafio. Você foi treinado pra isso.**
