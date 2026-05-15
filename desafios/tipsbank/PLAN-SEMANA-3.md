# PLAN-SEMANA-3 — Resiliência, Scheduling, Autoscaling e Observabilidade

> Guia ponta-a-ponta para subir o **TipsBank** completo (Semanas 1 + 2 + 3) em
> um cluster Kubernetes vazio. Funciona tanto em **KIND local** quanto em
> **EKS na AWS** — onde houver diferenças por ambiente, há um manifesto
> alternativo com sufixo `-kind` ao lado do original.

---

## Ambientes suportados

| Aspecto | KIND | EKS |
|---|---|---|
| Cluster | `kind create cluster --config k8s/semana3/kind-cluster.yaml` | `eksctl create cluster ...` (vide Semana 2) |
| Imagens | `kind load docker-image` (sem registry) | Pull do registry (ECR / Docker Hub) |
| Ingress-NGINX | Manifesto `deploy.yaml` versão KIND (HostPort 8080/8443) | Helm chart (LoadBalancer real) |
| Storage RWX (auditoria) | `09-nfs-kind.yaml` (local-path RWO + replicas=1) | `09-nfs.yaml` (NFS RWX + replicas=3) |
| Taint `compliance=strict` | Já aplicado no `tipsbank-worker3` via `kind-cluster.yaml` | Aplicar manualmente após criação |
| TLS | self-signed via cert-manager local | Let's Encrypt ou ACM |

---

## Resumo das mudanças por Etapa

| Etapa | O que muda | Arquivos |
|-------|-----------|---------|
| 3.1 | Corrigir startup probe thresholds; adicionar startup probe no `web` e `postgres` | Copiar `semana1/04..08` para `semana3/` e ajustar |
| 3.2 | Rollout strategy explícito no `api-transacoes` + `revisionHistoryLimit` | `semana3/06-api-transacoes.yaml` |
| 3.3 | `podAntiAffinity` em todos os Deployments com >1 réplica; postgres-replica com AntiAffinity Required; taint no worker3; tolerations no postgres | `semana3/04..08` + `semana3/22` |
| 3.4 | CPU limit no postgres e no web (eliminar BestEffort) | `semana3/04`, `semana3/08` |
| 3.5 | kube-prometheus-stack via Helm; ServiceMonitors para as 3 APIs; Ingress do Grafana | `semana3/23..24` + Helm |
| 3.6 | PrometheusRule com 4 alertas | `semana3/25` |
| 3.7 | Metrics Server + 3 HPAs + Locust como Deployment | `semana3/26..31` |
| 3.8 | DaemonSet de coleta em todos os workers | `semana3/32` |

---

## Fase 0 — Provisionar cluster e pré-requisitos

Antes de qualquer Etapa da Semana 3, o cluster precisa ter:

1. Cluster Kubernetes criado, com `kubectl` apontado para ele
2. Ingress-NGINX instalado
3. Namespaces criados
4. Secrets e ConfigMaps da Semana 1
5. Storage para a auditoria (NFS ou local-path)
6. cert-manager + ClusterIssuer (Semana 2)
7. NetworkPolicies default-deny (Semana 2 — aplicar **depois** dos workloads)

### 0.1 — Criar o cluster

#### KIND (local)

```bash
kind create cluster --config k8s/semana3/kind-cluster.yaml

# Carregar imagens locais no KIND (se não estiverem em registry público)
for img in api-contas:v1.1.0 api-transacoes:v1.2.0 auditoria:v1.1.0 web:v1.0.0; do
  kind load docker-image zenardi/tipsbank-${img} --name tipsbank
done

# /etc/hosts — KIND usa portas 8080/8443 no host
echo "127.0.0.1 app.tipsbank.local api.tipsbank.local grafana.tipsbank.local prometheus.tipsbank.local alertmanager.tipsbank.local locust.tipsbank.local" | sudo tee -a /etc/hosts
```

#### EKS (cloud)

```bash
# Cluster (configuração na Semana 2)
eksctl create cluster --config-file k8s/semana2/eks/eksctl-config.yaml
aws eks update-kubeconfig --name tipsbank --region us-east-1

# Taint compliance=strict no terceiro node (escolha um worker)
kubectl get nodes
kubectl taint nodes <NOME-DO-NODE-3> compliance=strict:NoSchedule
```

### 0.2 — Ingress-NGINX

Sem o controller do Ingress-NGINX, os objetos `Ingress` ficam sem `ADDRESS`
e o acesso pelo navegador não funciona. Instale **antes** dos workloads.

#### KIND

```bash
# Manifesto oficial KIND — usa HostPort 80/443 no control-plane
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

kubectl wait -n ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

# Validar — deve aparecer 1/1 Running
kubectl get pods -n ingress-nginx
```

#### EKS

```bash
# Helm chart oficial (provisiona um LoadBalancer real na AWS)
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait

# Pegar o hostname/IP do LB (use no DNS dos hostnames *.tipsbank.local)
kubectl get svc -n ingress-nginx
```

### 0.3 — Namespaces

```bash
kubectl apply -f k8s/semana1/00-namespaces.yaml
```

### 0.4 — Secrets e ConfigMaps (Semana 1)

```bash
kubectl apply -f k8s/semana1/01-secret-db.yaml
kubectl apply -f k8s/semana1/02-configmap-init-sql.yaml
kubectl apply -f k8s/semana1/03-configmap-nginx.yaml
```

### 0.5 — Storage para a auditoria

| Ambiente | Comando |
|---|---|
| **KIND** | `kubectl apply -f k8s/semana1/09-nfs-kind.yaml` (PVC local-path RWO 1Gi) |
| **EKS** | `kubectl apply -f k8s/semana1/09-nfs.yaml` (NFS server + PV RWX 5Gi) |

### 0.6 — cert-manager + ClusterIssuer (Semana 2)

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait

kubectl apply -f k8s/semana2/14-cert-manager-issuer.yaml
```

### 0.7 — NetworkPolicies default-deny (Semana 2)

> **Atenção**: aplique **depois** dos workloads (Fase 1). Caso contrário,
> os pods são isolados antes de subir e o DNS/CoreDNS fica inacessível,
> travando os initContainers. Se já aplicou antes, rode
> `kubectl rollout restart` nos Deployments para reagendar.

```bash
kubectl apply -f k8s/semana2/18-netpol-web.yaml
kubectl apply -f k8s/semana2/19-netpol-contas.yaml
kubectl apply -f k8s/semana2/20-netpol-transacoes.yaml
kubectl apply -f k8s/semana2/21-netpol-auditoria.yaml
```

---

## Etapa 3.1 — Probes completas

### O que está faltando

| Workload | Problema |
|----------|----------|
| `api-contas` | startupProbe: `failureThreshold: 20` (deve ser 30), `periodSeconds: 3` (deve ser 5) |
| `api-transacoes` | Mesmo problema do api-contas |
| `auditoria` | startupProbe: `failureThreshold: 10` (deve ser 30), `periodSeconds: 3` (deve ser 5) |
| `web` | Sem startupProbe |
| `postgres` | Sem startupProbe |

### Arquivo: `k8s/semana1/05-api-contas.yaml`

No Deployment `api-contas`, localize o bloco `startupProbe` e substitua:

```yaml
          startupProbe:
            httpGet:
              path: /health/startup
              port: 8080
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            periodSeconds: 5
            failureThreshold: 6
```

### Arquivo: `k8s/semana1/06-api-transacoes.yaml`

Mesma correção no container `api-transacoes` (não no sidecar):

```yaml
          startupProbe:
            httpGet:
              path: /health/startup
              port: 8080
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            periodSeconds: 5
            failureThreshold: 6
```

### Arquivo: `k8s/semana1/07-auditoria.yaml`

```yaml
          startupProbe:
            httpGet:
              path: /health/startup
              port: 8080
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            periodSeconds: 5
            failureThreshold: 6
```

### Arquivo: `k8s/semana1/08-web.yaml`

Adicione o `startupProbe` (ainda não existe) e corrija as probes existentes:

```yaml
          startupProbe:
            httpGet:
              path: /healthz
              port: 8080
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
            failureThreshold: 6
```

### Arquivo: `k8s/semana1/04-postgres.yaml`

Adicione `startupProbe` no container `postgres` e ajuste as probes existentes:

```yaml
          startupProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
```

### Aplicar e validar

```bash
kubectl apply -f k8s/semana3/04-postgres.yaml
kubectl apply -f k8s/semana3/05-api-contas.yaml
kubectl apply -f k8s/semana3/06-api-transacoes.yaml
kubectl apply -f k8s/semana3/07-auditoria.yaml
kubectl apply -f k8s/semana3/08-web.yaml

# Verificar probes configuradas
kubectl describe pod -n tipsbank-contas -l app=api-contas | grep -A 15 "Liveness\|Readiness\|Startup"
kubectl describe pod -n tipsbank-web -l app=web | grep -A 5 "Startup"

# Testar: kill do processo principal → pod deve reiniciar
kubectl exec -n tipsbank-contas \
  $(kubectl get pod -n tipsbank-contas -l app=api-contas -o name | head -1) \
  -- kill 1
kubectl get events -n tipsbank-contas --sort-by='.lastTimestamp' | tail -5
```

---

## Etapa 3.2 — Rollout strategy e rollback

### Arquivo: `k8s/semana1/06-api-transacoes.yaml`

No spec do Deployment, adicione logo após `replicas:` (antes de `selector:`):

```yaml
  replicas: 2
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

```bash
kubectl apply -f k8s/semana3/06-api-transacoes.yaml
```

### Testar rollback

```bash
# 1. Deploy de uma versão propositalmente quebrada
kubectl set image deployment/api-transacoes \
  api-transacoes=zenardi/tipsbank-api-transacoes:v99.0.0-broken \
  -n tipsbank-transacoes

# 2. Observar o rollout travando — maxUnavailable=0 garante que os pods antigos continuam
kubectl rollout status deployment/api-transacoes -n tipsbank-transacoes

# 3. Ver histórico (deve mostrar ao menos 2 revisões)
kubectl rollout history deployment/api-transacoes -n tipsbank-transacoes

# 4. Fazer rollback
kubectl rollout undo deployment/api-transacoes -n tipsbank-transacoes

# 5. Confirmar que voltou
kubectl rollout status deployment/api-transacoes -n tipsbank-transacoes
```

---

## Etapa 3.3 — Affinity, AntiAffinity, Taints e Tolerations

### Passo 1: Taint compliance=strict no nó 3

| Ambiente | Como aplicar |
|---|---|
| **KIND** | Já aplicado automaticamente no `tipsbank-worker3` via `kubeadmConfigPatches` no `kind-cluster.yaml`. |
| **EKS** | Aplicar manualmente após `eksctl create cluster`. |

```bash
# Listar nodes para identificar o terceiro worker
kubectl get nodes

# EKS: substitua <NODE-3> pelo nome real do terceiro worker
kubectl taint nodes <NODE-3> compliance=strict:NoSchedule

# Validar (qualquer ambiente)
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'
```

### Passo 2: podAntiAffinity em todos os Deployments com >1 réplica

Adicione o bloco `affinity` dentro de `spec.template.spec` em cada Deployment abaixo:

#### `k8s/semana1/05-api-contas.yaml`

```yaml
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: api-contas
                topologyKey: kubernetes.io/hostname
```

#### `k8s/semana1/06-api-transacoes.yaml`

```yaml
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: api-transacoes
                topologyKey: kubernetes.io/hostname
```

#### `k8s/semana1/07-auditoria.yaml`

```yaml
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: auditoria
                topologyKey: kubernetes.io/hostname
```

#### `k8s/semana1/08-web.yaml`

```yaml
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: web
                topologyKey: kubernetes.io/hostname
```

### Passo 3: Label + Tolerations + AntiAffinity Required no Postgres primary

No StatefulSet `k8s/semana1/04-postgres.yaml`:

1. Adicione o label `role: primary` no template:

```yaml
    metadata:
      labels:
        app: postgres
        role: primary
```

2. Dentro de `spec.template.spec`, adicione tolerations e affinity:

```yaml
      tolerations:
        - key: "compliance"
          operator: "Equal"
          value: "strict"
          effect: "NoSchedule"
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: postgres
              topologyKey: kubernetes.io/hostname
```

### Passo 4: Criar postgres-replica StatefulSet

Crie o arquivo `k8s/semana3/22-postgres-replica.yaml`:

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-replica
  namespace: tipsbank-contas
  labels:
    app: postgres
    role: replica
spec:
  clusterIP: None
  selector:
    app: postgres
    role: replica
  ports:
    - port: 5432
      name: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres-replica
  namespace: tipsbank-contas
spec:
  serviceName: postgres-replica
  replicas: 1
  selector:
    matchLabels:
      app: postgres
      role: replica
  template:
    metadata:
      labels:
        app: postgres
        role: replica
    spec:
      tolerations:
        - key: "compliance"
          operator: "Equal"
          value: "strict"
          effect: "NoSchedule"
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: postgres
              topologyKey: kubernetes.io/hostname
      initContainers:
        - name: wait-primary
          image: busybox:1.36
          command:
            - sh
            - -c
            - "until nc -zw3 postgres.tipsbank-contas.svc.cluster.local 5432; do echo 'aguardando primary...'; sleep 3; done"
      containers:
        - name: postgres-replica
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: tipsbank
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: secret-db
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: secret-db
                  key: POSTGRES_PASSWORD
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          startupProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init-sql
              mountPath: /docker-entrypoint-initdb.d/
      volumes:
        - name: init-sql
          configMap:
            name: configmap-init-sql
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 2Gi
```

> **Nota didática**: esta réplica sobe com o mesmo init.sql e age como um banco independente para exercitar StatefulSet + AntiAffinity. Em produção real, usaria `pg_basebackup` + `primary_conninfo` para replicação streaming.

### Aplicar e validar

```bash
kubectl apply -f k8s/semana3/04-postgres.yaml
kubectl apply -f k8s/semana3/05-api-contas.yaml
kubectl apply -f k8s/semana3/06-api-transacoes.yaml
kubectl apply -f k8s/semana3/07-auditoria.yaml
kubectl apply -f k8s/semana3/08-web.yaml
kubectl apply -f k8s/semana3/22-postgres-replica.yaml

# Primary e replica devem estar em nodes diferentes
kubectl get pods -o wide -n tipsbank-contas | grep postgres

# Pods de API não devem estar no node com taint
kubectl get pods -o wide -A | grep tipsbank

# Confirmar taint
kubectl describe node worker2 | grep -A 5 Taints
```

---

## Etapa 3.4 — Resources, Limits e QoS

### Arquivo: `k8s/semana3/04-postgres.yaml`

Adicione o CPU limit (estava ausente):

```yaml
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
```

### Arquivo: `k8s/semana3/08-web.yaml`

Adicione o CPU limit (estava ausente):

```yaml
          resources:
            requests:
              cpu: "10m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```

### Validar QoS

```bash
kubectl apply -f k8s/semana3/04-postgres.yaml
kubectl apply -f k8s/semana3/08-web.yaml

# Checar QoS — nenhum deve ser BestEffort
kubectl get pods -A -o json | \
  jq -r '.items[] | select(.metadata.namespace | startswith("tipsbank")) | "\(.metadata.namespace)/\(.metadata.name): \(.status.qosClass)"'
```

Resultado esperado: todos `Burstable`. Nenhum `BestEffort`.

---

## Etapa 3.5 — Observabilidade: kube-prometheus + Grafana

### Passo 1: Instalar o kube-prometheus-stack via Helm

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace tipsbank-monitoring

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace tipsbank-monitoring \
  --set grafana.adminPassword=giropops \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --wait

# Confirmar que tudo subiu
kubectl get pods -n tipsbank-monitoring
```

### Passo 2: ServiceMonitors para as 3 APIs

Crie `k8s/semana3/23-servicemonitors.yaml`:

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api-contas
  namespace: tipsbank-contas
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: api-contas
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api-transacoes
  namespace: tipsbank-transacoes
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: api-transacoes
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: auditoria
  namespace: tipsbank-auditoria
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: auditoria
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

> **Atenção**: o ServiceMonitor usa `port: http` — verifique o nome da porta nos seus Services:
> ```bash
> kubectl get svc -n tipsbank-contas api-contas -o yaml | grep -A 5 "ports:"
> ```
> Se a porta não tiver nome `http`, adicione `name: http` ao Service, ou substitua por `port: "8080"` no endpoint.

```bash
kubectl apply -f k8s/semana3/23-servicemonitors.yaml
```

### Passo 3: Ingress para Grafana, Prometheus e Alertmanager

Crie `k8s/semana3/24-monitoring-ingress.yaml`:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: tipsbank-monitoring
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: tipsbank-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - grafana.tipsbank.local
      secretName: grafana-tls
  rules:
    - host: grafana.tipsbank.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-grafana
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: tipsbank-monitoring
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: tipsbank-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - prometheus.tipsbank.local
      secretName: prometheus-tls
  rules:
    - host: prometheus.tipsbank.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-prometheus
                port:
                  number: 9090
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: alertmanager
  namespace: tipsbank-monitoring
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: tipsbank-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - alertmanager.tipsbank.local
      secretName: alertmanager-tls
  rules:
    - host: alertmanager.tipsbank.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-alertmanager
                port:
                  number: 9093
```

```bash
kubectl apply -f k8s/semana3/24-monitoring-ingress.yaml

# Adicionar entradas no /etc/hosts (use o IP do Ingress Controller)
INGRESS_IP=$(kubectl get svc -A -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "192.168.56.10")
echo "$INGRESS_IP grafana.tipsbank.local prometheus.tipsbank.local alertmanager.tipsbank.local locust.tipsbank.local" | sudo tee -a /etc/hosts
```

### Passo 4: Dashboard no Grafana

Acesse `https://grafana.tipsbank.local` com `admin / giropops`. Importe:

- **Dashboard ID 7249** — Kubernetes Cluster
- **Dashboard ID 6417** — Kubernetes Pod Metrics

Para métricas customizadas das APIs, crie um dashboard com as queries:

```promql
# Requests/s por endpoint
rate(http_requests_total{namespace=~"tipsbank-.*"}[5m])

# Latência p50/p95/p99
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{namespace=~"tipsbank-.*"}[5m]))

# Taxa de erros 5xx
sum(rate(http_requests_total{status=~"5..",namespace=~"tipsbank-.*"}[5m])) /
sum(rate(http_requests_total{namespace=~"tipsbank-.*"}[5m]))

# CPU por pod
rate(container_cpu_usage_seconds_total{namespace=~"tipsbank-.*"}[5m])

# Memória por pod
container_memory_working_set_bytes{namespace=~"tipsbank-.*"}
```

---

## Etapa 3.6 — PrometheusRule com alertas de SLO

Crie `k8s/semana3/25-prometheusrule.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: tipsbank-slo-alerts
  namespace: tipsbank-monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: tipsbank.slo
      interval: 30s
      rules:

        - alert: TipsBankApiDown
          expr: up{job=~"tipsbank-contas/api-contas|tipsbank-transacoes/api-transacoes|tipsbank-auditoria/auditoria"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "API {{ $labels.job }} está down"
            description: "Target {{ $labels.instance }} sem resposta há mais de 2 minutos."

        - alert: TipsBankP99Alto
          expr: |
            histogram_quantile(0.99,
              sum by (job, le) (
                rate(http_request_duration_seconds_bucket{namespace=~"tipsbank-.*"}[5m])
              )
            ) > 0.5
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "P99 de latência acima de 500ms em {{ $labels.job }}"
            description: "P99 atual = {{ $value | humanizeDuration }}"

        - alert: TipsBankErroAltoApi
          expr: |
            (
              sum by (job) (rate(http_requests_total{status=~"5..",namespace=~"tipsbank-.*"}[3m]))
              /
              sum by (job) (rate(http_requests_total{namespace=~"tipsbank-.*"}[3m]))
            ) > 0.05
          for: 3m
          labels:
            severity: critical
          annotations:
            summary: "Taxa de erros 5xx > 5% em {{ $labels.job }}"
            description: "Taxa atual: {{ $value | humanizePercentage }}"

        - alert: TipsBankPodCrashLoop
          expr: increase(kube_pod_container_status_restarts_total{namespace=~"tipsbank-.*"}[10m]) > 3
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} em CrashLoop"
            description: "{{ $value }} restarts nos últimos 10 minutos no namespace {{ $labels.namespace }}."
```

```bash
kubectl apply -f k8s/semana3/25-prometheusrule.yaml

# Verificar
kubectl get prometheusrule -A

# Testar TipsBankApiDown: escale a API para 0 réplicas e aguarde 2 min
kubectl scale deployment api-contas -n tipsbank-contas --replicas=0
# Aguardar 2+ min, ver alerta no Alertmanager
# Restaurar
kubectl scale deployment api-contas -n tipsbank-contas --replicas=2
```

---

## Etapa 3.7 — HPA + Metrics Server + Locust stress test

### Passo 1: Instalar o Metrics Server

Em kubeadm local, o Metrics Server requer `--kubelet-insecure-tls`. Crie `k8s/semana3/26-metrics-server.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: metrics-server
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
    rbac.authorization.k8s.io/aggregate-to-view: "true"
  name: system:aggregated-metrics-reader
rules:
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods", "nodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: metrics-server
  name: system:metrics-server
rules:
  - apiGroups: [""]
    resources: ["nodes/metrics"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["pods", "nodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server-auth-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
  - kind: ServiceAccount
    name: metrics-server
    namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server:system:auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRoleBinding
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: metrics-server
    namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-app: metrics-server
  name: system:metrics-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:metrics-server
subjects:
  - kind: ServiceAccount
    name: metrics-server
    namespace: kube-system
---
apiVersion: v1
kind: Service
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  ports:
    - name: https
      port: 443
      protocol: TCP
      targetPort: https
  selector:
    k8s-app: metrics-server
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server
  strategy:
    rollingUpdate:
      maxUnavailable: 0
  template:
    metadata:
      labels:
        k8s-app: metrics-server
    spec:
      containers:
        - args:
            - --cert-dir=/tmp
            - --secure-port=10250
            - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
            - --kubelet-use-node-status-port
            - --metric-resolution=15s
            - --kubelet-insecure-tls
          image: registry.k8s.io/metrics-server/metrics-server:v0.7.2
          imagePullPolicy: IfNotPresent
          livenessProbe:
            failureThreshold: 3
            httpGet:
              path: /livez
              port: https
              scheme: HTTPS
            periodSeconds: 10
          name: metrics-server
          ports:
            - containerPort: 10250
              name: https
              protocol: TCP
          readinessProbe:
            failureThreshold: 3
            httpGet:
              path: /readyz
              port: https
              scheme: HTTPS
            initialDelaySeconds: 20
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 200Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 1000
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - mountPath: /tmp
              name: tmp-dir
      nodeSelector:
        kubernetes.io/os: linux
      priorityClassName: system-cluster-critical
      serviceAccountName: metrics-server
      volumes:
        - emptyDir: {}
          name: tmp-dir
---
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  labels:
    k8s-app: metrics-server
  name: v1beta1.metrics.k8s.io
spec:
  group: metrics.k8s.io
  groupPriorityMinimum: 100
  insecureSkipTLSVerify: true
  service:
    name: metrics-server
    namespace: kube-system
  version: v1beta1
  versionPriority: 100
```

```bash
kubectl apply -f k8s/semana3/26-metrics-server.yaml
kubectl rollout status deployment/metrics-server -n kube-system

# Confirmar funcionamento
kubectl top nodes
kubectl top pods -A | grep tipsbank
```

### Passo 2: HPA para api-contas

Crie `k8s/semana3/27-hpa-api-contas.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-contas
  namespace: tipsbank-contas
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-contas
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
```

### Passo 3: HPA para api-transacoes (ContainerResource)

Crie `k8s/semana3/28-hpa-api-transacoes.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-transacoes
  namespace: tipsbank-transacoes
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-transacoes
  minReplicas: 3
  maxReplicas: 15
  metrics:
    # ContainerResource: mede apenas o container "api-transacoes", excluindo o sidecar
    - type: ContainerResource
      containerResource:
        name: cpu
        container: api-transacoes
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 3
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
```

### Passo 4: HPA para auditoria (Memory)

Crie `k8s/semana3/29-hpa-auditoria.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: auditoria
  namespace: tipsbank-auditoria
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: auditoria
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 75
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
```

```bash
kubectl apply -f k8s/semana3/27-hpa-api-contas.yaml
kubectl apply -f k8s/semana3/28-hpa-api-transacoes.yaml
kubectl apply -f k8s/semana3/29-hpa-auditoria.yaml

kubectl get hpa -A
```

### Passo 5: Build e distribuição da imagem Locust

```bash
docker build -t zenardi/tipsbank-locust:v1.0.0 locust/
```

**Distribuir a imagem (depende do ambiente):**

| Ambiente | Comando |
|---|---|
| **KIND** | `kind load docker-image zenardi/tipsbank-locust:v1.0.0 --name tipsbank` |
| **EKS** | `docker push zenardi/tipsbank-locust:v1.0.0` (configure `imagePullSecrets` se o registry for privado) |

### Passo 6: Locust como Deployment no cluster

Crie `k8s/semana3/30-locust-deployment.yaml`:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: locust
  namespace: tipsbank-monitoring
  labels:
    app: locust
spec:
  replicas: 1
  selector:
    matchLabels:
      app: locust
  template:
    metadata:
      labels:
        app: locust
    spec:
      containers:
        - name: locust
          image: zenardi/tipsbank-locust:v1.0.0
          ports:
            - containerPort: 8089
              name: http
          env:
            - name: LOCUST_HOST
              value: "http://api-transacoes.tipsbank-transacoes.svc.cluster.local:8080"
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          livenessProbe:
            httpGet:
              path: /
              port: 8089
            initialDelaySeconds: 10
            periodSeconds: 30
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: locust
  namespace: tipsbank-monitoring
  labels:
    app: locust
spec:
  selector:
    app: locust
  ports:
    - port: 8089
      targetPort: 8089
      name: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: locust
  namespace: tipsbank-monitoring
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: tipsbank-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - locust.tipsbank.local
      secretName: locust-tls
  rules:
    - host: locust.tipsbank.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: locust
                port:
                  number: 8089
```

### Passo 7: NetworkPolicy permitindo Locust → api-transacoes

O namespace `tipsbank-transacoes` tem default-deny. Crie `k8s/semana3/31-netpol-locust.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-locust-ingress
  namespace: tipsbank-transacoes
spec:
  podSelector:
    matchLabels:
      app: api-transacoes
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-monitoring
          podSelector:
            matchLabels:
              app: locust
      ports:
        - protocol: TCP
          port: 8080
```

```bash
kubectl apply -f k8s/semana3/30-locust-deployment.yaml
kubectl apply -f k8s/semana3/31-netpol-locust.yaml
```

### Passo 8: Rodar o stress test

Acesse `https://locust.tipsbank.local`, configure:
- **Number of users**: 200
- **Spawn rate**: 20
- **Duration**: 5m

Monitore o HPA escalando em outro terminal:

```bash
watch kubectl get hpa -A
watch kubectl get pods -n tipsbank-transacoes
```

Critério de aceite: réplicas de `api-transacoes` sobem para >5 durante o teste.

---

## Etapa 3.8 — DaemonSet de coleta

Crie `k8s/semana3/32-daemonset-node-collector.yaml`:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-collector
  namespace: tipsbank-monitoring
  labels:
    app: node-collector
spec:
  selector:
    matchLabels:
      app: node-collector
  template:
    metadata:
      labels:
        app: node-collector
    spec:
      # Tolera o nó com taint compliance=strict — coleta em TODOS os workers
      tolerations:
        - key: "compliance"
          operator: "Equal"
          value: "strict"
          effect: "NoSchedule"
        - key: "node-role.kubernetes.io/control-plane"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - name: collector
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              while true; do
                echo "=== $(date) | node=$(hostname) ==="
                df -h / | tail -1
                free -m | grep Mem
                echo "uptime: $(cat /proc/uptime)"
                sleep 30
              done
          resources:
            requests:
              cpu: "5m"
              memory: "16Mi"
            limits:
              cpu: "20m"
              memory: "32Mi"
          volumeMounts:
            - name: host-root
              mountPath: /host-root
              readOnly: true
      volumes:
        - name: host-root
          hostPath:
            path: /
      terminationGracePeriodSeconds: 10
```

```bash
kubectl apply -f k8s/semana3/32-daemonset-node-collector.yaml

# DESIRED deve ser igual ao número de nodes (control-plane + workers)
kubectl get ds -n tipsbank-monitoring

# Ver logs de um dos pods
kubectl logs -n tipsbank-monitoring -l app=node-collector --prefix | head -20
```

---

## Resumo dos arquivos criados/modificados

### Em `k8s/semana1/` (usados como estão na Fase 0)

| Arquivo | Uso |
|---|---|
| `00-namespaces.yaml` | Cria os 5 namespaces `tipsbank-*` |
| `01-secret-db.yaml` | Secret `contas-db-secret` (POSTGRES_USER/PASSWORD/DB + DB_URL) |
| `02-configmap-init-sql.yaml` | ConfigMap `postgres-init-sql` com schema da Semana 1 |
| `03-configmap-nginx.yaml` | ConfigMap `nginx-config` para o web |
| `09-nfs.yaml` | NFS server + PV RWX 5Gi (**uso em EKS**) |
| `09-nfs-kind.yaml` | PVC local-path RWO 1Gi (**uso em KIND**) |

### Em `k8s/semana2/` (usados como estão na Fase 0)

| Arquivo | Uso |
|---|---|
| `14-cert-manager-issuer.yaml` | ClusterIssuer `tipsbank-issuer` |
| `18..21-netpol-*.yaml` | NetworkPolicies default-deny por namespace |

### Em `k8s/semana3/` (cópias modificadas dos manifestos da Semana 1)

| Arquivo | O que muda vs Semana 1 |
|---|---|
| `04-postgres.yaml` | Startup probe; CPU limit; label `role: primary`; affinity Anti Required |
| `05-api-contas.yaml` | Startup probe thresholds (30/5); affinity preferred |
| `06-api-transacoes.yaml` | Startup probe (30/5); rollout strategy; revisionHistoryLimit 5; affinity preferred |
| `07-auditoria.yaml` | Startup probe (30/5); affinity preferred (**uso em EKS**) |
| `07-auditoria-kind.yaml` | replicas=1 com RWO (**uso em KIND**) |
| `08-web.yaml` | Startup probe novo (/healthz); CPU limit; affinity preferred |

### Em `k8s/semana3/` (novos da Semana 3)

| Arquivo | Conteúdo |
|---|---|
| `kind-cluster.yaml` | Config de cluster KIND multi-node (CP + 3 workers + taint) |
| `22-postgres-replica.yaml` | StatefulSet postgres-replica + Headless Service |
| `23-servicemonitors.yaml` | ServiceMonitor para as 3 APIs |
| `24-monitoring-ingress.yaml` | Ingress Grafana, Prometheus, Alertmanager |
| `25-prometheusrule.yaml` | 4 alertas SLO |
| `26-metrics-server.yaml` | Metrics Server com `--kubelet-insecure-tls` |
| `27-hpa-api-contas.yaml` | HPA min 2 max 10 CPU 70% |
| `28-hpa-api-transacoes.yaml` | HPA min 3 max 15 ContainerResource CPU 70% |
| `29-hpa-auditoria.yaml` | HPA min 2 max 6 Memory 75% |
| `30-locust-deployment.yaml` | Locust Deployment + Service + Ingress |
| `31-netpol-locust.yaml` | NetworkPolicy Ingress (transacoes) + Egress (monitoring) |
| `32-daemonset-node-collector.yaml` | DaemonSet em todos os nodes |

---

## Ordem recomendada de aplicação (cluster vazio)

### Fase 0 — Cluster + pré-requisitos

```bash
# 0.1 — Cluster (escolha KIND ou EKS — ver detalhes na seção Fase 0 acima)

# 0.2 — Ingress-NGINX
# KIND:
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait -n ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s
# OU EKS:
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait

# 0.3 — Namespaces
kubectl apply -f k8s/semana1/00-namespaces.yaml

# 0.4 — Secrets, ConfigMaps
kubectl apply -f k8s/semana1/01-secret-db.yaml
kubectl apply -f k8s/semana1/02-configmap-init-sql.yaml
kubectl apply -f k8s/semana1/03-configmap-nginx.yaml

# 0.5 — Storage para a auditoria (escolha por ambiente)
kubectl apply -f k8s/semana1/09-nfs-kind.yaml      # KIND
# OU
kubectl apply -f k8s/semana1/09-nfs.yaml           # EKS

# 0.6 — cert-manager + ClusterIssuer
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait
kubectl apply -f k8s/semana2/14-cert-manager-issuer.yaml
```

### Fase 1 — Aplicação (Etapas 3.1 a 3.4)

```bash
kubectl apply -f k8s/semana3/04-postgres.yaml
kubectl apply -f k8s/semana3/05-api-contas.yaml
kubectl apply -f k8s/semana3/06-api-transacoes.yaml
kubectl apply -f k8s/semana3/08-web.yaml

# Auditoria — escolha por ambiente
kubectl apply -f k8s/semana3/07-auditoria-kind.yaml    # KIND (replicas=1, RWO)
# OU
kubectl apply -f k8s/semana3/07-auditoria.yaml          # EKS (replicas=3, RWX)

# Réplica do postgres (Etapa 3.3)
kubectl apply -f k8s/semana3/22-postgres-replica.yaml

# Aguardar pods ficarem Ready
kubectl get pods -A -w
```

### Fase 2 — Observabilidade (Etapas 3.5 e 3.6)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace tipsbank-monitoring \
  --set grafana.adminPassword=giropops \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --wait

kubectl apply -f k8s/semana3/23-servicemonitors.yaml
kubectl apply -f k8s/semana3/24-monitoring-ingress.yaml
kubectl apply -f k8s/semana3/25-prometheusrule.yaml
```

### Fase 3 — Autoscaling (Etapa 3.7)

```bash
# Metrics Server
kubectl apply -f k8s/semana3/26-metrics-server.yaml
kubectl rollout status deployment/metrics-server -n kube-system

# HPAs
kubectl apply -f k8s/semana3/27-hpa-api-contas.yaml
kubectl apply -f k8s/semana3/28-hpa-api-transacoes.yaml
kubectl apply -f k8s/semana3/29-hpa-auditoria.yaml

# Locust — build e distribuição
docker build -t zenardi/tipsbank-locust:v1.0.0 locust/
kind load docker-image zenardi/tipsbank-locust:v1.0.0 --name tipsbank   # KIND
# OU
docker push zenardi/tipsbank-locust:v1.0.0                              # EKS

kubectl apply -f k8s/semana3/30-locust-deployment.yaml
kubectl apply -f k8s/semana3/31-netpol-locust.yaml
```

### Fase 4 — DaemonSet (Etapa 3.8)

```bash
kubectl apply -f k8s/semana3/32-daemonset-node-collector.yaml
```

### Fase 5 — NetworkPolicies (aplicar SÓ depois de tudo Ready)

```bash
kubectl apply -f k8s/semana2/18-netpol-web.yaml
kubectl apply -f k8s/semana2/19-netpol-contas.yaml
kubectl apply -f k8s/semana2/20-netpol-transacoes.yaml
kubectl apply -f k8s/semana2/21-netpol-auditoria.yaml

# Se algum pod ficar isolado, reagende:
kubectl rollout restart -n tipsbank-contas deployment/api-contas
kubectl rollout restart -n tipsbank-transacoes deployment/api-transacoes
```

### Fase 6 — Acesso pelo navegador

| Ambiente | Comando |
|---|---|
| **KIND** | `echo "127.0.0.1 app.tipsbank.local api.tipsbank.local grafana.tipsbank.local prometheus.tipsbank.local alertmanager.tipsbank.local locust.tipsbank.local" \| sudo tee -a /etc/hosts` |
| **EKS** | Configurar DNS (A-record) dos hostnames para o LoadBalancer do Ingress: `kubectl get svc -n ingress-nginx` |

---

## Checkpoint Semana 3 — Validação final

```bash
# Probes em todas as APIs
kubectl describe pod -n tipsbank-contas -l app=api-contas | grep -A 20 "Liveness\|Readiness\|Startup"
kubectl describe pod -n tipsbank-web -l app=web | grep -A 5 "Startup"

# Rollout strategy
kubectl get deployment api-transacoes -n tipsbank-transacoes \
  -o jsonpath='{.spec.strategy}{"\n"}'
kubectl rollout history deployment/api-transacoes -n tipsbank-transacoes

# AntiAffinity — postgres em nodes diferentes
kubectl get pods -o wide -n tipsbank-contas | grep postgres

# Taint no worker2
kubectl describe node worker2 | grep -A 5 Taints

# QoS — nenhum BestEffort
kubectl get pods -A -o json | jq -r \
  '.items[] | select(.metadata.namespace | startswith("tipsbank")) | "\(.metadata.namespace)/\(.metadata.name): \(.status.qosClass)"'

# Prometheus targets UP
kubectl port-forward -n tipsbank-monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
# http://localhost:9090/targets

# PrometheusRules ativas
kubectl get prometheusrule -A

# HPAs com métricas
kubectl get hpa -A

# Metrics Server funcionando
kubectl top nodes
kubectl top pods -n tipsbank-transacoes

# DaemonSet em todos os workers
kubectl get ds -n tipsbank-monitoring
# DESIRED == CURRENT == READY == número de nodes

# Locust UI
curl -sk https://locust.tipsbank.local | grep -i locust
```
