# Etapa 1.4 — Namespaces, Deployments, StatefulSet e Services: Detalhamento das Mudanças

## Objetivo da etapa

Subir toda a stack TipsBank no cluster kubeadm criado na etapa 1.3:

- 4 namespaces isolados (um por serviço)
- Postgres como `StatefulSet` com PVC de 2Gi e seed via ConfigMap
- 3 APIs + frontend como `Deployment` (2 réplicas cada)
- Services `ClusterIP` para comunicação interna
- nginx do frontend com upstreams FQDN cross-namespace (ConfigMap sobrepõe o arquivo baked na imagem)
- Acesso via `kubectl port-forward` (sem Ingress ainda)

---

## Arquivos novos criados em `k8s/semana1/`

### `00-namespaces.yaml`

4 namespaces criados. Cada serviço em namespace próprio (isolamento e critério de nomes distintos de recursos):

```yaml
tipsbank-contas      # Postgres + api-contas
tipsbank-transacoes  # api-transacoes
tipsbank-auditoria   # auditoria
tipsbank-web         # frontend nginx
```

---

### `01-secret-db.yaml`

Secret `Opaque` no namespace `tipsbank-contas` com todas as credenciais do Postgres:

```yaml
kind: Secret
metadata:
  name: postgres-credentials   # (renomeado para contas-db-secret na etapa 1.5)
  namespace: tipsbank-contas
stringData:
  POSTGRES_USER:     tipsbank
  POSTGRES_PASSWORD: tipsbank
  POSTGRES_DB:       tipsbank
  DB_URL: "postgresql+psycopg://tipsbank:tipsbank@postgres:5432/tipsbank"
```

> `DB_URL` com short name (`postgres`) funciona pois api-contas está no mesmo namespace.  
> Para api-transacoes (namespace diferente), o FQDN é obrigatório — veja `06-api-transacoes.yaml`.

---

### `02-configmap-init-sql.yaml`

Schema + seed do Postgres montado em `/docker-entrypoint-initdb.d/` (executado apenas no primeiro boot):

```yaml
kind: ConfigMap
metadata:
  name: postgres-init-sql
  namespace: tipsbank-contas
data:
  init.sql: |
    CREATE TABLE IF NOT EXISTS contas (...)
    CREATE TABLE IF NOT EXISTS transacoes (...)
    -- Seed: 2 contas, senha "giropops" (bcrypt pré-computado)
    INSERT INTO contas (id, titular, documento, senha_hash, saldo) VALUES
        ('11111111-...', 'Jeferson Fernando', '12345678901', '$2b$10$...', 10000.00),
        ('22222222-...', 'LinuxTips SA',      '98765432100', '$2b$10$...',   500.00)
    ON CONFLICT (documento) DO NOTHING;
```

> A senha `giropops` está pré-computada em bcrypt para evitar inicialização dinâmica.  
> `ON CONFLICT DO NOTHING` garante idempotência em re-provisionamentos.

---

### `03-configmap-nginx.yaml`

nginx.conf com upstreams FQDN inter-namespace para o Kubernetes.

**Problema a resolver:** a imagem `web` (etapa 1.1) foi buildada com o `nginx.conf` do docker-compose, onde os upstreams usam short names (`api-contas`, `auditoria`). No Kubernetes, serviços em namespaces diferentes não são resolvíveis por short name.

**Solução:** montar um ConfigMap que sobrepõe `/etc/nginx/nginx.conf` da imagem usando `subPath` (sem substituir o diretório inteiro `/etc/nginx/`):

```yaml
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: tipsbank-web
data:
  nginx.conf: |
    upstream contas     { server api-contas.tipsbank-contas.svc.cluster.local:8080; }
    upstream transacoes { server api-transacoes.tipsbank-transacoes.svc.cluster.local:8080; }
    upstream auditoria  { server auditoria.tipsbank-auditoria.svc.cluster.local:8080; }
    ...
```

> `pid /tmp/nginx.pid` e `*_temp_path /tmp/...`: caminhos em `/tmp` porque o container roda como `nginx` (não root) e não tem permissão de escrita em `/var/run/`.

---

### `04-postgres.yaml`

Dois documentos: Headless Service + StatefulSet.

**Headless Service** (`clusterIP: None`): registra o DNS `postgres-0.postgres.tipsbank-contas.svc.cluster.local` e permite que pods no mesmo namespace usem o short name `postgres`.

**StatefulSet:**

```yaml
spec:
  serviceName: postgres
  replicas: 1
  containers:
    - name: postgres
      image: postgres:16-alpine
      envFrom:
        - secretRef:
            name: contas-db-secret       # (era postgres-credentials, renomeado na etapa 1.5)
      volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        - name: init-sql
          mountPath: /docker-entrypoint-initdb.d/
      readinessProbe:
        exec: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
  volumes:
    - name: init-sql
      configMap:
        name: postgres-init-sql
  volumeClaimTemplates:
    - name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storage: 2Gi                     # StorageClass default do cluster
```

> **Pré-requisito:** `local-path-provisioner` instalado e marcado como default StorageClass (bare kubeadm não tem StorageClass padrão).

---

### `05-api-contas.yaml`

Deployment (2 réplicas) + ClusterIP Service no namespace `tipsbank-contas`.

- `initContainer` aguarda o Postgres via `nc -zw3 postgres 5432` antes de subir
- `DB_URL` via `secretKeyRef` apontando para o Secret do namespace
- Probes: liveness (`/health/live`), readiness (`/health/ready`), startup (`/health/startup`)

---

### `06-api-transacoes.yaml`

Inclui seu próprio Secret com a `DB_URL` usando FQDN (namespace diferente):

```yaml
DB_URL: "postgresql+psycopg://...@postgres.tipsbank-contas.svc.cluster.local:5432/tipsbank"
```

Dois `initContainers` em série:
1. `wait-postgres` — aguarda porta 5432 do Postgres (FQDN cross-namespace)
2. `wait-api-contas` — aguarda `/health/ready` da api-contas (FQDN cross-namespace)

> `CONTAS_URL` e `AUDITORIA_URL` ainda eram `value:` inline nesta etapa (migrados para ConfigMap na etapa 1.5).

---

### `07-auditoria.yaml`

Deployment (2 réplicas) + ClusterIP Service no namespace `tipsbank-auditoria`.

Ponto de atenção: a auditoria grava eventos em `/data` (arquivo JSON local). O docker-compose usa um `auditoria-init` container para `chown -R 65532:65532 /data`. No Kubernetes o equivalente é `securityContext.fsGroup`:

```yaml
spec:
  securityContext:
    fsGroup: 65532   # GID 65532 = nonroot (Chainguard); garante write no emptyDir
  volumes:
    - name: data
      emptyDir: {}   # temporário — será substituído por PVC NFS na etapa 1.6
```

---

### `08-web.yaml`

Deployment (2 réplicas) + ClusterIP Service no namespace `tipsbank-web`.

O `nginx.conf` do ConfigMap é montado com `subPath` para sobrepor apenas o arquivo, sem substituir o diretório:

```yaml
volumeMounts:
  - name: nginx-config
    mountPath: /etc/nginx/nginx.conf
    subPath: nginx.conf       # sobrepõe só o arquivo, não o diretório inteiro
    readOnly: true
volumes:
  - name: nginx-config
    configMap:
      name: nginx-config
```

---

## Arquivos modificados nas imagens Docker

### Dockerfiles — `apps/{api-contas,api-transacoes,auditoria}/Dockerfile`

**Problema crítico descoberto durante a etapa:**  
As imagens v1.0.0 foram buildadas com `python:3.11-slim-bookworm` como builder, compilando `pydantic-core==2.9.2` para Python 3.11. Porém o runtime `cgr.dev/chainguard/python:latest` em abril de 2026 já era Python 3.14. O módulo `pydantic_core._pydantic_core.cpython-311` não carregava no Python 3.14 — **ABI mismatch**.

**Erro observado nos pods:**
```
ModuleNotFoundError: No module named 'pydantic_core._pydantic_core'
```

**Correção:**

```diff
-FROM python:3.11-slim-bookworm AS builder
+FROM cgr.dev/chainguard/python:latest-dev AS builder   # mesma versão Python do runtime
+
+USER root    # necessário: chainguard/python:latest-dev roda como nonroot por padrão
              # pip install sem root falha ao escrever em /packages

 RUN pip3 install --no-cache-dir --target=/packages -r requirements.txt
-#   ^^ era: pip install (falha — Chainguard não expõe "pip" diretamente, só "pip3")
```

### `requirements.txt` — das 3 APIs Python

```diff
-pydantic==2.9.2
+pydantic>=2.9.2    # permite instalar 2.13.3 que tem wheels nativos para Python 3.14
```

> `pydantic==2.9.2` não tem wheel para Python 3.14 (pre-release à época) e o build source falhava.  
> `pydantic>=2.9.2` resolve para 2.13.3 que inclui wheels `cp314`.

**Nova tag:** `v1.1.0` para as 3 APIs (rebuild + push)

---

## Infraestrutura de cluster adicionada

### `local-path-provisioner` (StorageClass padrão)

Bare kubeadm não tem StorageClass. Para que os `volumeClaimTemplates` do Postgres funcionem:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Cria PVs dinamicamente no path `/opt/local-path-provisioner/` em cada node.

---

## Resumo dos recursos criados no cluster

| Recurso | Kind | Namespace |
|---|---|---|
| `tipsbank-contas` | Namespace | — |
| `tipsbank-transacoes` | Namespace | — |
| `tipsbank-auditoria` | Namespace | — |
| `tipsbank-web` | Namespace | — |
| `postgres-credentials` | Secret | tipsbank-contas |
| `postgres-init-sql` | ConfigMap | tipsbank-contas |
| `nginx-config` | ConfigMap | tipsbank-web |
| `postgres` | Service (Headless) | tipsbank-contas |
| `postgres` | StatefulSet | tipsbank-contas |
| `api-contas` | Deployment | tipsbank-contas |
| `api-contas` | Service | tipsbank-contas |
| `postgres-credentials`* | Secret | tipsbank-transacoes |
| `api-transacoes` | Deployment | tipsbank-transacoes |
| `api-transacoes` | Service | tipsbank-transacoes |
| `auditoria` | Deployment | tipsbank-auditoria |
| `auditoria` | Service | tipsbank-auditoria |
| `web` | Deployment | tipsbank-web |
| `web` | Service | tipsbank-web |

> \* `postgres-credentials` em `tipsbank-transacoes` viola o critério de nomes distintos — corrigido na etapa 1.5 para `transacoes-db-secret`.

---

## Critérios de aceite verificados

```
✅ kubectl get pods -A | grep tipsbank → todos Running
✅ kubectl port-forward -n tipsbank-transacoes svc/api-transacoes 8080:8080
     curl -X POST /transferencias → {"status":"concluida"}
✅ kubectl port-forward -n tipsbank-web svc/web 8080:8080
     SPA abre no browser, login e transferência funcionam
✅ StatefulSet postgres: 1/1 Running, PVC 2Gi Bound (local-path)
✅ Deployments: api-contas 2/2, api-transacoes 2/2, auditoria 2/2, web 2/2
```
