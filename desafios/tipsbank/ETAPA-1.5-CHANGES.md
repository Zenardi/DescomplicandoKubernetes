# Etapa 1.5 — Pod Multicontainer + ConfigMap/Secret: Detalhamento das Mudanças

## Objetivo da etapa

- `api-transacoes` vira pod **multicontainer** (app + sidecar `log-forwarder`)
- Container principal escreve logs em arquivo (`/var/log/app/app.log`)
- Sidecar lê o arquivo via volume `emptyDir` compartilhado e repassa para stdout
- Todas as credenciais migram para `Secret`; todas as URLs e parâmetros para `ConfigMap`
- Secrets e ConfigMaps com **nomes distintos** por namespace (sem compartilhamento cross-namespace)

---

## 1. `apps/api-transacoes/main.py`

**O que mudou:** adição de um `FileHandler` de log (linhas 23–30).

```python
# File handler — ativado quando LOG_FILE está definido (sidecar log-forwarder lê o arquivo)
_LOG_FILE = os.getenv("LOG_FILE", "")
if _LOG_FILE:
    import pathlib
    pathlib.Path(_LOG_FILE).parent.mkdir(parents=True, exist_ok=True)
    _fh = logging.FileHandler(_LOG_FILE)
    _fh.setFormatter(logging.Formatter(_LOG_FMT))
    logging.getLogger().addHandler(_fh)
```

**Comportamento:**
- `LOG_FILE` ausente → apenas stdout (comportamento anterior inalterado)
- `LOG_FILE=/var/log/app/app.log` → escreve no arquivo **e** no stdout simultaneamente
- Usa o mesmo formato JSON (`_LOG_FMT`) em ambos os handlers

**Nova imagem:** `zenardi/tipsbank-api-transacoes:v1.2.0` (rebuild + push)

---

## 2. `k8s/semana1/01-secret-db.yaml`

**O que mudou:** renomeação do Secret no namespace `tipsbank-contas`.

```diff
-  name: postgres-credentials
+  name: contas-db-secret
```

**Motivo:** o critério da etapa exige nomes de Secret distintos por namespace.  
`contas-db-secret` (tipsbank-contas) ≠ `transacoes-db-secret` (tipsbank-transacoes)

---

## 3. `k8s/semana1/04-postgres.yaml`

**O que mudou:** referência ao Secret atualizada para o novo nome.

```diff
 secretKeyRef:
-  name: postgres-credentials
+  name: contas-db-secret
   key: DB_URL
```

---

## 4. `k8s/semana1/05-api-contas.yaml`

### 4a. Novo documento `ConfigMap` adicionado

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: contas-app-config        # nome único no namespace tipsbank-contas
  namespace: tipsbank-contas
data:
  LOG_LEVEL: INFO
```

### 4b. Deployment — env vars migradas para referências declarativas

```diff
-  - name: LOG_LEVEL
-    value: INFO
+  - name: LOG_LEVEL
+    valueFrom:
+      configMapKeyRef:
+        name: contas-app-config
+        key: LOG_LEVEL

   - name: DB_URL
     valueFrom:
       secretKeyRef:
-        name: postgres-credentials
+        name: contas-db-secret
         key: DB_URL
```

---

## 5. `k8s/semana1/06-api-transacoes.yaml` — Reescrita completa

O arquivo passou de **2 documentos** (Deployment + Service) para **4 documentos**.

### Documento 1 — Secret `transacoes-db-secret` (novo)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: transacoes-db-secret     # ≠ contas-db-secret
  namespace: tipsbank-transacoes
type: Opaque
stringData:
  DB_URL: "postgresql+psycopg://tipsbank:tipsbank@postgres.tipsbank-contas.svc.cluster.local:5432/tipsbank"
```

> Credencial sensível isolada em Secret. FQDN obrigatório pois o Postgres está em outro namespace.

### Documento 2 — ConfigMap `transacoes-app-config` (novo)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: transacoes-app-config    # ≠ contas-app-config
  namespace: tipsbank-transacoes
data:
  CONTAS_URL:    "http://api-contas.tipsbank-contas.svc.cluster.local:8080"
  AUDITORIA_URL: "http://auditoria.tipsbank-auditoria.svc.cluster.local:8080"
  LOG_LEVEL:     "INFO"
  LOG_FILE:      "/var/log/app/app.log"   # ativa o FileHandler em main.py
```

> Parâmetros não-sensíveis: URLs de serviços e caminho do arquivo de log.

### Documento 3 — Deployment (mudanças principais)

| Aspecto | Antes | Depois |
|---|---|---|
| Image tag | `v1.1.0` | `v1.2.0` |
| Secret ref | `postgres-credentials` | `transacoes-db-secret` |
| `CONTAS_URL` | `value: "http://..."` inline | `configMapKeyRef` |
| `AUDITORIA_URL` | `value: "http://..."` inline | `configMapKeyRef` |
| `LOG_LEVEL` | `value: INFO` inline | `configMapKeyRef` |
| `LOG_FILE` | ausente | `configMapKeyRef` → ativa FileHandler |
| Volume | nenhum | `emptyDir` montado em `/var/log/app` |
| Containers | 1 | **2** (main + sidecar `log-forwarder`) |

**Volume `emptyDir` compartilhado:**
```yaml
volumes:
  - name: log-volume
    emptyDir: {}
```
Montado em `/var/log/app` nos dois containers.

**Container principal — volumeMount adicionado:**
```yaml
volumeMounts:
  - name: log-volume
    mountPath: /var/log/app
```

**Sidecar `log-forwarder` — adicionado:**
```yaml
- name: log-forwarder
  image: busybox:1.36
  command:
    - sh
    - -c
    - 'until [ -f /var/log/app/app.log ]; do sleep 1; done; tail -F /var/log/app/app.log'
  volumeMounts:
    - name: log-volume
      mountPath: /var/log/app
  resources:
    requests:
      cpu: "5m"
      memory: "16Mi"
    limits:
      memory: "32Mi"
```

> O `until` evita crash do sidecar caso o arquivo ainda não exista no startup.
> `tail -F` (maiúsculo) reabre o arquivo se for rotacionado.

### Documento 4 — Service (inalterado)

Sem nenhuma mudança em relação à etapa 1.4.

---

## 6. `ENTREGA.md` — Seção 1.5 atualizada

Comandos corrigidos com os nomes reais dos recursos e adicionado loop para verificar
o sidecar nos dois pods (o tráfego via Service pode cair em qualquer réplica):

```bash
for pod in $(kubectl get pod -n tipsbank-transacoes -l app=api-transacoes \
    -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $pod ===" && kubectl logs -n tipsbank-transacoes "$pod" -c log-forwarder --tail=10
done
```

---

## Recursos criados/deletados no cluster

| Recurso | Namespace | Ação |
|---|---|---|
| `secret/contas-db-secret` | tipsbank-contas | ✅ Criado |
| `secret/transacoes-db-secret` | tipsbank-transacoes | ✅ Criado |
| `configmap/contas-app-config` | tipsbank-contas | ✅ Criado |
| `configmap/transacoes-app-config` | tipsbank-transacoes | ✅ Criado |
| `secret/postgres-credentials` | tipsbank-contas | 🗑️ Deletado |
| `secret/postgres-credentials` | tipsbank-transacoes | 🗑️ Deletado |
| `deployment/api-contas` | tipsbank-contas | 🔄 Rollout (nova CM ref) |
| `deployment/api-transacoes` | tipsbank-transacoes | 🔄 Rollout (v1.2.0, 2 containers) |

---

## Critérios de aceite verificados

```
✅ kubectl get pods -n tipsbank-transacoes → 2/2 Running (dois containers por pod)
✅ kubectl logs -c log-forwarder <pod>     → JSON estruturado da app
✅ kubectl get deployment api-transacoes -o yaml | grep -A5 valueFrom
      → secretKeyRef e configMapKeyRef; nenhum value inline sensível
✅ contas-db-secret ≠ transacoes-db-secret (nomes distintos por namespace)
✅ contas-app-config ≠ transacoes-app-config (nomes distintos por namespace)
```

**Exemplo de output do sidecar após uma transferência:**
```json
{"ts":"2026-04-22 19:42:01,649","level":"INFO","service":"api-transacoes","msg":"bootstrap versao=v1.2.0"}
{"ts":"2026-04-22 19:43:43,650","level":"INFO","service":"api-transacoes","msg":"transferencia id=55fc07b6-6ba9-482b-97e0-64e2c7a38352 origem=11111111-... destino=22222222-... valor=5.0"}
{"ts":"2026-04-22 19:43:43,675","level":"INFO","service":"api-transacoes","msg":"HTTP Request: POST http://api-contas.tipsbank-contas.svc.cluster.local:8080/contas/.../saldo \"HTTP/1.1 200 OK\""}
{"ts":"2026-04-22 19:43:43,699","level":"INFO","service":"api-transacoes","msg":"HTTP Request: POST http://auditoria.tipsbank-auditoria.svc.cluster.local:8080/eventos \"HTTP/1.1 201 Created\""}
```
