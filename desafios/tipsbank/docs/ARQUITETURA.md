# TipsBank — Arquitetura

Documento descreve a arquitetura **alvo** no Kubernetes após o aluno concluir todas as semanas do desafio.

## 1. Visão geral

O **TipsBank** é um banco digital fictício composto por três microsserviços, um banco de dados e um volume compartilhado de auditoria. Tudo roda em Kubernetes, separado por namespaces que representam áreas da empresa (contas, transações, auditoria) com isolamento de rede, RBAC e políticas de compliance aplicadas via Kyverno.

## 2. Componentes da aplicação

| Componente | Tipo | Linguagem | Porta | Descrição |
|---|---|---|---|---|
| `web` | Deployment | nginx-unprivileged (Alpine) + HTML/JS vanilla | 8080 | SPA internet banking (landing, login, dashboard, transferir, extrato); faz proxy reverso para as 3 APIs em `/api/*` |
| `api-contas` | Deployment | Python/FastAPI | 8080 | CRUD de contas bancárias, ajuste de saldo, autenticação via `POST /login` (bcrypt) |
| `api-transacoes` | Deployment | Python/FastAPI | 8080 | Transferências, extratos; chama `api-contas` e publica em `auditoria` |
| `auditoria` | Deployment | Python/FastAPI | 8080 | Recebe eventos e grava em `/data` (PV NFS compartilhado) |
| `postgres-primary` | StatefulSet | PostgreSQL 16 | 5432 | Banco principal de contas e transações |
| `postgres-replica` | StatefulSet | PostgreSQL 16 | 5432 | Réplica read-only (Day-7 — affinity obriga node separado) |
| `nfs-server` | StatefulSet | nfs-ganesha | 2049 | Servidor NFS consumido pela `auditoria` via PV/PVC |

## 3. Namespaces

```
tipsbank-contas       -> api-contas + postgres-primary + postgres-replica
tipsbank-transacoes   -> api-transacoes
tipsbank-auditoria    -> auditoria + nfs-server
tipsbank-monitoring   -> kube-prometheus-stack (Grafana, Prometheus, Alertmanager)
tipsbank-ingress      -> ingress-nginx + cert-manager
tipsbank-policies     -> kyverno
```

Todos os namespaces da aplicação recebem **NetworkPolicy default-deny** e **Kyverno policies** gerados automaticamente (Day-15 Generate).

## 4. Diagrama de fluxo

```
              +--------------------------------------------------------+
              |                  Internet (TLS)                        |
              +----------------------------+---------------------------+
                                           |
                                           v
                             +-------------+--------------+
                             |     Ingress-NGINX          |
                             |  (cert-manager, TLS,       |
                             |   Auth, rate-limit,        |
                             |   Canary, affinity cookie) |
                             +------+----------------+----+
                                    |                |
                  host: contas.     |                | host: app.
                  tipsbank.local    v                v    tipsbank.local
                  +-----------------+---+    +-------+---------------+
                  |   Service:          |    |   Service:            |
                  |   api-contas        |    |   api-transacoes      |
                  |   (ClusterIP)       |    |   (ClusterIP)         |
                  +----+----------+-----+    +---+----------+--------+
                       |          |              |          |
                       |          | sidecar      |          |
                       v          v              v          v
                 +-----+----+ +---+----+   +-----+----+ +---+--------+
                 | Pod      | | Pod    |   | Pod      | | Pod        |
                 | api-     | | api-   |   | api-     | | api-       |
                 | contas 1 | | contas2|   | trans. 1 | | trans. 2   |
                 |          | |        |   |  +----+  | |  +-----+   |
                 |          | |        |   |  |side|  | |  |side |   |
                 |          | |        |   |  |log |  | |  |log  |   |
                 +----+-----+ +--------+   +--+-+--+--+ +--+-+---+---+
                      |                       |              |
                      | (JDBC)                | (HTTP)       | (HTTP)
                      v                       v              v
             +--------+---------+    +--------+-------+  +---+--------------+
             | StatefulSet      |    | Service:       |  | Service:         |
             | postgres-primary |<---+ api-contas     |  | auditoria        |
             | + replica (STS)  |    | (via NetPol)   |  +--+---------------+
             | + Headless Svc   |    +----------------+     |
             +--------+---------+                           v
                      |                            +--------+--------+
                      | PVC (StorageClass)         | Deployment      |
                      v                            | auditoria (2)   |
             +--------+---------+                  +--------+--------+
             | PV (local-path   |                           |
             |  ou EBS no EKS)  |                           | PVC RWX
             +------------------+                           v
                                                   +--------+--------+
                                                   | PV NFS (RWX)    |
                                                   | -> nfs-server   |
                                                   |    (STS)        |
                                                   +-----------------+

Namespaces isolados por NetworkPolicy default-deny +
Kyverno enforcing: sem root, sem :latest, registry confiavel,
imagens com assinatura Cosign.

kube-prometheus coleta via ServiceMonitor/PodMonitor de todos os namespaces.
```

## 5. Comunicação entre serviços

| Origem | Destino | Protocolo | Observação |
|---|---|---|---|
| Internet | Ingress | HTTPS 443 | TLS via cert-manager |
| Ingress | `web` svc | HTTP 8080 | Rota principal `app.tipsbank.local` (SPA) |
| Ingress | `api-contas` svc | HTTP 8080 | Rota `api.tipsbank.local/contas` |
| Ingress | `api-transacoes` svc | HTTP 8080 | Rota `api.tipsbank.local/transacoes` com **Canary** |
| `web` | `api-contas`, `api-transacoes`, `auditoria` | HTTP 8080 | Proxy reverso interno `/api/*` (em K8s pode ser substituído por Ingress rotas) |
| `api-transacoes` | `api-contas` svc | HTTP 8080 | Liberado via NetworkPolicy (cross-namespace) |
| `api-transacoes` | `auditoria` svc | HTTP 8080 | Liberado via NetworkPolicy (cross-namespace) |
| `api-contas` | `postgres-primary` | TCP 5432 | Mesmo namespace; só pods com label `role=app` acessam |
| `api-transacoes` | `postgres-primary` | TCP 5432 | NetPol entre namespaces |
| `auditoria` | `nfs-server` svc | TCP 2049 | NFS via Headless Service |
| Prometheus (ns monitoring) | `/metrics` de todas as APIs | HTTP 8080 | Liberado via ServiceMonitor + NetPol |

## 6. Estratégia de storage

- `postgres-primary`: PVC com StorageClass default (gp3 no EKS, local-path no kubeadm)
- `auditoria`: PVC **RWX** apontando para PV NFS — vários pods escrevem no mesmo volume
- Os arquivos `/data/eventos-YYYY-MM-DD.jsonl` devem estar acessíveis e legíveis de qualquer réplica da `auditoria`

## 7. Estratégia de rollout

- `api-transacoes` usa **Deployment com rolling update** `maxSurge: 1, maxUnavailable: 0`
- Novas versões são promovidas via **Canary de Ingress Nginx** (header `X-Canary: true` ou 10% do tráfego via weight annotation)
- Rollback disparado via `kubectl rollout undo` quando o alerta `P99Degradado` dispara

## 8. Estratégia de escalabilidade

| Componente | HPA min-max | Métrica |
|---|---|---|
| `api-contas` | 2-10 | CPU 70% |
| `api-transacoes` | 3-15 | **ContainerResource** CPU 70% no container app (exclui sidecar) |
| `auditoria` | 2-6 | Memory 75% |
| Postgres | fixo (STS) | — |

Metrics-Server obrigatório no cluster (Day-14).

## 9. Mapeamento Day → componente

| Day | Onde aparece |
|---|---|
| 1 | Cluster kind inicial na semana 1 |
| 2 | Pod multicontainer (`api-transacoes` com sidecar de log); EmptyDir compartilhado entre app e sidecar |
| 3 | Deployments + rolling update + rollback em todas as APIs |
| 4 | ReplicaSet (implícito), DaemonSet (coletor de node), Probes nas 3 APIs |
| 5 | Cluster kubeadm 3 nodes na semana 1, depois EKS na semana 2 |
| 6 | PV NFS + PVC RWX para `auditoria`; StorageClass para Postgres |
| 7 | StatefulSet do Postgres + Headless Service; Services de todos os tipos |
| 8 | ConfigMap (nginx.conf do ingress custom; configs das apps); Secrets Opaque (DB), TLS (cert), dockerconfigjson (registry privado) |
| 9 | Ingress Nginx Controller no kubeadm E no EKS |
| 10 | TLS via cert-manager, Auth na rota `/admin`, Affinity Cookie, Rate limit, **Canary** entre v1 e v2 de transações |
| 11 | kube-prometheus-stack via Helm; Grafana + Prometheus + Alertmanager |
| 12 | ServiceMonitor por API, PodMonitor no sidecar, PrometheusRule com alertas de SLO |
| 13 | Build Wolfi/Distroless, Trivy com 0 HIGH/CRITICAL, Cosign assinando tudo |
| 14 | HPA em cada API com métrica diferente; Locust stress test como Deployment |
| 15 | Kyverno: Validate (sem root, sem latest), Mutate (injeta labels), Generate (NetPol default-deny por ns) |
| 16 | Postgres primary+replica com AntiAffinity obrigatório; nodes taint `compliance=strict` |
| 17 | NetworkPolicy default-deny por namespace, allow cross-ns explícito, ipBlock com except |
| 18 | RBAC: 4 perfis com certificado X.509 (operador-contas, operador-transacoes, auditor-global ClusterRole, sre) |
| 19 | **Helm Chart umbrella** empacotando app + policies + monitoring |
