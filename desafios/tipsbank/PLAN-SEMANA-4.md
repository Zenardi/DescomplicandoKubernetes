# PLAN-SEMANA-4 — Compliance, RBAC, Helm e Entrega Final

> Guia ponta-a-ponta para fechar o **TipsBank** com policies (Kyverno),
> segregação de acesso (RBAC com certificados X.509 + ServiceAccounts),
> empacotamento via **Helm Chart umbrella** e a checklist de compliance
> final (BACEN-style). Os comandos cobrem **KIND local** e **EKS na AWS**;
> onde houver diferença, há um bloco por ambiente.
>
> **Pré-requisito**: Semanas 1, 2 e 3 já concluídas (cluster com app
> rodando, Ingress/TLS, NetworkPolicies, kube-prometheus, HPA, Locust).
> Veja `PLAN-SEMANA-3.md` para subir um cluster do zero até esse ponto.

---

## Ambientes suportados

| Aspecto | KIND | EKS |
|---|---|---|
| Cluster | `kind create cluster --config k8s/semana3/kind-cluster.yaml` | `eksctl create cluster --config-file k8s/semana2/eks/cluster-config-network-policy.yaml` |
| Registry de imagens | `zenardi/tipsbank-*` (Docker Hub) | `zenardi/tipsbank-*` (Docker Hub) ou ECR |
| CA do cluster (RBAC X.509) | `/etc/kubernetes/pki/ca.{crt,key}` no nó control-plane do KIND | EKS **não expõe** a chave da CA — usar `CertificateSigningRequest` ou IAM/aws-auth para usuários humanos |
| Distribuição de imagens | `kind load docker-image ...` | `docker push ...` (ou ECR) |
| Helm repo (chart umbrella) | local (path) ou GitHub Pages | GitHub Pages, OCI ghcr.io ou ECR Helm |

---

## Resumo das mudanças por Etapa

| Etapa | O que entrega | Arquivos |
|-------|---------------|----------|
| 4.1 | 3 ClusterPolicies Kyverno **Validate** (no-root, no-latest, require-labels) | `k8s/semana4/40-kyverno-validate-*.yaml` |
| 4.2 | 1 ClusterPolicy Kyverno **Mutate** (injeta securityContext) | `k8s/semana4/43-kyverno-mutate-securitycontext.yaml` |
| 4.3 | 1 ClusterPolicy Kyverno **Generate** (default-deny por ns novo) + policy de registry confiável | `k8s/semana4/44-kyverno-generate-netpol.yaml`, `45-kyverno-validate-registry.yaml` |
| 4.4 | 4 perfis RBAC com X.509 + 2 ServiceAccounts com Token | `k8s/semana4/rbac/` + `evidencias/kubeconfigs/` |
| 4.5 | Helm Chart umbrella `helm/tipsbank/` com subcharts/templates | `helm/tipsbank/` |
| 4.6 | Script de compliance final | `scripts/compliance-check.sh` |
| 4.7 | Roteiro do vídeo demo | `docs/ROTEIRO-VIDEO.md` |

---

## Fase 0 — Bootstrap completo a partir de cluster vazio (Semanas 1, 2 e 3)

> Pule esta seção se você está continuando de um cluster onde **PLAN-SEMANA-3.md** já foi aplicado
> e todos os pods estão `Running`. Caso contrário, execute os passos abaixo em ordem para
> subir toda a infra das semanas anteriores antes de iniciar a Semana 4.

### 0.1 — Criar o cluster

#### KIND (local)

```bash
# Cria cluster 3-nodes com taint compliance=strict no worker3
kind create cluster --config k8s/semana3/kind-cluster.yaml

# Carregar imagens no KIND (se não estiverem em registry público)
for img in api-contas:v1.1.0 api-transacoes:v1.2.0 auditoria:v1.1.0 web:v1.0.0 locust:v1.0.0; do
  kind load docker-image zenardi/tipsbank-${img} --name tipsbank
done

# /etc/hosts — adicionar os hostnames do lab
echo "127.0.0.1 app.tipsbank.local api.tipsbank.local grafana.tipsbank.local prometheus.tipsbank.local alertmanager.tipsbank.local locust.tipsbank.local" | sudo tee -a /etc/hosts
```

#### EKS (cloud)

```bash
eksctl create cluster --config-file k8s/semana2/eks/eksctl-config.yaml
aws eks update-kubeconfig --name tipsbank --region us-east-1

# Taint compliance=strict no terceiro node
kubectl get nodes
kubectl taint nodes <NOME-DO-NODE-3> compliance=strict:NoSchedule
```

### 0.2 — Ingress-NGINX

> Instale antes dos workloads. Sem o controller, os `Ingress` ficam sem ADDRESS.

#### KIND

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

kubectl wait -n ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s
```

#### EKS

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait

# Anote o hostname/IP do LoadBalancer para configurar o DNS
kubectl get svc -n ingress-nginx
```

### 0.3 — Namespaces, Secrets e ConfigMaps (Semana 1)

```bash
kubectl apply -f k8s/semana1/00-namespaces.yaml
kubectl apply -f k8s/semana1/01-secret-db.yaml
kubectl apply -f k8s/semana1/02-configmap-init-sql.yaml
kubectl apply -f k8s/semana1/03-configmap-nginx.yaml
```

### 0.4 — Storage para a Auditoria (Semana 1)

| Ambiente | Comando |
|---|---|
| **KIND** | `kubectl apply -f k8s/semana1/09-nfs-kind.yaml` (PVC local-path RWO 1Gi) |
| **EKS**  | `kubectl apply -f k8s/semana1/09-nfs.yaml` (NFS server + PV RWX 5Gi) |

### 0.5 — cert-manager + ClusterIssuer (Semana 2)

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait

# ClusterIssuer self-signed → CA → tipsbank-ca-issuer
kubectl apply -f k8s/semana2/14-cert-manager-issuer.yaml

# Aguardar a CA estar pronta antes de subir os Ingresses com TLS
kubectl wait --for=condition=Ready certificate/tipsbank-ca \
  -n cert-manager --timeout=120s
```

### 0.6 — Workloads principais (Semana 3 — versões atualizadas dos manifests)

> Os arquivos de `k8s/semana3/` sobrescrevem os equivalentes da Semana 1
> (probes completas, resources/limits, affinity e taint tolerations).

```bash
# Workloads principais
kubectl apply -f k8s/semana3/04-postgres.yaml
kubectl apply -f k8s/semana3/05-api-contas.yaml
kubectl apply -f k8s/semana3/06-api-transacoes.yaml

# Auditoria — escolha conforme ambiente
kubectl apply -f k8s/semana3/07-auditoria-kind.yaml   # KIND (RWO, 1 réplica)
# OU
kubectl apply -f k8s/semana3/07-auditoria.yaml         # EKS (RWX, 3 réplicas)

kubectl apply -f k8s/semana3/08-web.yaml

# Réplica do PostgreSQL (Semana 3)
kubectl apply -f k8s/semana3/22-postgres-replica.yaml

# Aguardar todos os pods subirem antes de aplicar as NetworkPolicies
kubectl wait --for=condition=ready pod -l app=api-contas \
  -n tipsbank-contas --timeout=180s
kubectl wait --for=condition=ready pod -l app=api-transacoes \
  -n tipsbank-transacoes --timeout=180s
kubectl wait --for=condition=ready pod -l app=auditoria \
  -n tipsbank-auditoria --timeout=180s
kubectl wait --for=condition=ready pod -l app=web \
  -n tipsbank-web --timeout=120s
```

### 0.7 — Ingresses e Canary (Semana 2)

```bash
# Ingresses principais (TLS via tipsbank-ca-issuer)
kubectl apply -f k8s/semana2/10-ingress-app.yaml
kubectl apply -f k8s/semana2/11-ingress-contas.yaml
kubectl apply -f k8s/semana2/12-ingress-transacoes.yaml
kubectl apply -f k8s/semana2/13-ingress-auditoria.yaml

# Basic-auth para Ingress de APIs internas
kubectl apply -f k8s/semana2/15-basic-auth-secret.yaml

# Canary v2 da api-transacoes (10% do tráfego)
kubectl apply -f k8s/semana2/16-api-transacoes-v2.yaml
kubectl apply -f k8s/semana2/17-ingress-canary.yaml
```

### 0.8 — NetworkPolicies default-deny (Semana 2)

> **Atenção**: aplique **depois** dos workloads estarem `Running`.
> Antes disso, o CoreDNS fica inacessível e os initContainers travam.

```bash
kubectl apply -f k8s/semana2/18-netpol-web.yaml
kubectl apply -f k8s/semana2/19-netpol-contas.yaml
kubectl apply -f k8s/semana2/20-netpol-transacoes.yaml
kubectl apply -f k8s/semana2/21-netpol-auditoria.yaml
```

### 0.9 — kube-prometheus-stack (Semana 3)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace tipsbank-monitoring --create-namespace \
  --set grafana.adminPassword=giropops \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --wait
```

### 0.10 — Observabilidade, HPA, Locust e DaemonSet (Semana 3)

```bash
# ServiceMonitors para as 3 APIs
kubectl apply -f k8s/semana3/23-servicemonitors.yaml

# Ingresses do Grafana / Prometheus / Alertmanager
kubectl apply -f k8s/semana3/24-monitoring-ingress.yaml

# Alertas Prometheus (PrometheusRule)
kubectl apply -f k8s/semana3/25-prometheusrule.yaml

# Metrics Server (necessário para HPA)
kubectl apply -f k8s/semana3/26-metrics-server.yaml

# HPAs
kubectl apply -f k8s/semana3/27-hpa-api-contas.yaml
kubectl apply -f k8s/semana3/28-hpa-api-transacoes.yaml
kubectl apply -f k8s/semana3/29-hpa-auditoria.yaml

# Locust (gerador de carga)
kubectl apply -f k8s/semana3/30-locust-deployment.yaml
kubectl apply -f k8s/semana3/31-netpol-locust.yaml

# DaemonSet de coleta de métricas de node
kubectl apply -f k8s/semana3/32-daemonset-node-collector.yaml
```

### 0.11 — Verificação rápida (cluster deve estar 100% saudável)

```bash
# Todos os pods tipsbank-* devem estar Running ou Completed
kubectl get pods -A | grep tipsbank | grep -v Running | grep -v Completed
# Esperado: vazio

# Namespaces
kubectl get ns | grep tipsbank

# HPAs
kubectl get hpa -A

# PrometheusRule e ServiceMonitors
kubectl get prometheusrule -A
kubectl get servicemonitor -A

# NetworkPolicies
kubectl get netpol -A | grep tipsbank

# Smoke test das APIs (KIND)
curl -sk https://app.tipsbank.local/ | grep -i tipsbank
curl -sk https://api.tipsbank.local/contas/health/live
curl -sk https://api.tipsbank.local/transacoes/health/live
curl -sk https://api.tipsbank.local/auditoria/health/live
```

> Com tudo `Running` e os health checks retornando `200`, o cluster está pronto
> para a Semana 4. Prossiga para a **Etapa 4.1**.

---

## Etapa 4.1 — Kyverno: Validate (proibir root, proibir latest, exigir labels)

### O que entrega

3 `ClusterPolicy` em modo **enforce** que rejeitam manifests fora do padrão:

| Policy | Bloqueia |
|---|---|
| `disallow-root-user` | Pods com `runAsUser: 0` (em pod ou container) |
| `disallow-latest-tag` | Imagens sem tag explícita ou com `:latest` |
| `require-labels` | Deployments / STS / DS sem labels `app`, `team`, `env` |

### Passo 1: Instalar o Kyverno

> O Kyverno **precisa** subir antes das policies. Em ambos os ambientes a instalação é via Helm.

#### KIND e EKS

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --set replicaCount=1 \
  --wait

# Validar
kubectl get pods -n kyverno
kubectl get crd | grep kyverno
```

> **Nota EKS**: em EKS de produção use `--set replicaCount=3` para HA. Para desafio/lab, 1 réplica basta.

### Passo 2: Adicionar labels obrigatórias nos workloads existentes

Antes de aplicar a `require-labels`, garanta que **todos** os workloads do TipsBank já têm `team: tipsbank` e `env: <prod|lab|dev>`. Caso contrário o próximo `helm upgrade` ou `kubectl rollout restart` será bloqueado.

```bash
# Patch em massa — repita para todos os Deployments e o StatefulSet
for ns in tipsbank-contas tipsbank-transacoes tipsbank-auditoria tipsbank-web; do
  kubectl get deploy,sts -n $ns -o name | while read r; do
    kubectl label -n $ns $r team=tipsbank env=lab --overwrite
  done
done
```

> Os arquivos `k8s/semana3/04..08-*.yaml` já têm `app: <nome>`. As labels `team` e `env` devem ser adicionadas no `metadata.labels` do recurso e também no `spec.template.metadata.labels`.

### Passo 3: Criar as 3 policies

#### Arquivo: `k8s/semana4/40-kyverno-validate-no-root.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-root-user
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-runasnonroot
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Pods nao podem rodar como root (runAsUser != 0). UID 0 e proibido."
        pattern:
          spec:
            =(securityContext):
              =(runAsUser): ">0"
            containers:
              - name: "*"
                =(securityContext):
                  =(runAsUser): ">0"
```

#### Arquivo: `k8s/semana4/41-kyverno-validate-no-latest.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Toda imagem precisa de uma tag explicita (nao pode ser :latest e nao pode estar sem tag)."
        pattern:
          spec:
            containers:
              - name: "*"
                image: "!*:latest & *:*"
```

#### Arquivo: `k8s/semana4/42-kyverno-validate-require-labels.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-labels-app-team-env
      match:
        any:
          - resources:
              kinds: [Deployment, StatefulSet, DaemonSet]
      validate:
        message: "Workloads precisam das labels: app, team, env."
        pattern:
          metadata:
            labels:
              app: "?*"
              team: "?*"
              env: "?*"
```

### Aplicar e validar

```bash
mkdir -p k8s/semana4
# (criar os 3 arquivos acima)

kubectl apply -f k8s/semana4/40-kyverno-validate-no-root.yaml
kubectl apply -f k8s/semana4/41-kyverno-validate-no-latest.yaml
kubectl apply -f k8s/semana4/42-kyverno-validate-require-labels.yaml

# Devem aparecer com READY=true
kubectl get cpol

# Criterio de aceite — 3 tentativas que DEVEM ser bloqueadas:
kubectl run ruim-root --image=nginx:1.27 --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' --dry-run=server -o yaml
kubectl run ruim-latest --image=nginx:latest --dry-run=server
kubectl create deployment ruim-labels --image=nginx:1.27 --dry-run=server -o yaml | kubectl apply --dry-run=server -f -

# Cole as mensagens de erro do Kyverno em EVIDENCIAS.md.
```

> **Atenção**: se algum pod do TipsBank for bloqueado pela `require-labels`, volte ao Passo 2.

---

## Etapa 4.2 — Kyverno: Mutate (injetar securityContext)

### O que entrega

Uma `ClusterPolicy` Mutate que **injeta automaticamente** os campos:

- `runAsNonRoot: true`
- `readOnlyRootFilesystem: true`
- `allowPrivilegeEscalation: false`

em pods que não os tenham definidos. Aplica-se a `Pod` na criação.

### Arquivo: `k8s/semana4/43-kyverno-mutate-securitycontext.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: mutate-security-context
spec:
  background: false
  rules:
    - name: add-default-securitycontext
      match:
        any:
          - resources:
              kinds: [Pod]
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                securityContext:
                  +(runAsNonRoot): true
                  +(readOnlyRootFilesystem): true
                  +(allowPrivilegeEscalation): false
```

### Aplicar e validar

```bash
kubectl apply -f k8s/semana4/43-kyverno-mutate-securitycontext.yaml

# Teste — pod minimalista deve receber os campos injetados
kubectl run teste-mutate --image=nginx:1.27 --restart=Never --command -- sleep 3600

kubectl get pod teste-mutate -o jsonpath='{.spec.containers[0].securityContext}{"\n"}'
# Esperado: {"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"runAsNonRoot":true}

kubectl delete pod teste-mutate
```

### Tratamento do `readOnlyRootFilesystem` para o TipsBank

`readOnlyRootFilesystem: true` quebra processos que precisam escrever em `/tmp` ou paths de runtime. Para o TipsBank:

- **APIs Distroless (`api-contas`, `api-transacoes`, `auditoria`)** — já são imutáveis. Adicione `emptyDir` em `/tmp` se a app usar `tempfile`.
- **`web` (nginx-unprivileged)** — precisa de `emptyDir` em `/var/cache/nginx`, `/var/run` e `/tmp`.
- **`postgres`** — precisa do volume `data` em `/var/lib/postgresql/data` (já existe via PVC) **e** `emptyDir` em `/tmp`.

Se algum workload existente quebrar, crie uma `PolicyException` específica para ele:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: tipsbank-postgres-rorfs-exception
  namespace: tipsbank-contas
spec:
  exceptions:
    - policyName: mutate-security-context
      ruleNames: [add-default-securitycontext]
  match:
    any:
      - resources:
          kinds: [Pod]
          selector:
            matchLabels:
              app: postgres
```

### Critérios de aceite

```bash
# Pod novo recebe os campos
kubectl run check-rorfs --image=nginx:1.27 --restart=Never --command -- sleep 60
kubectl get pod check-rorfs -o jsonpath='{.spec.containers[0].securityContext}{"\n"}'
kubectl delete pod check-rorfs

# Todos os pods do TipsBank continuam Running
kubectl get pods -A | grep tipsbank | grep -v Running
# (esperado: vazio)
```

---

## Etapa 4.3 — Kyverno: Generate (NetworkPolicy automática) + Registry confiável

### O que entrega

1. `ClusterPolicy` **Generate** que cria uma `NetworkPolicy` default-deny em todo namespace **novo**.
2. `ClusterPolicy` **Validate** que rejeita imagens fora dos registries confiáveis.

### Arquivo: `k8s/semana4/44-kyverno-generate-netpol.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-default-deny-netpol
spec:
  background: false
  rules:
    - name: gen-netpol-default-deny
      match:
        any:
          - resources:
              kinds: [Namespace]
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-public
                - kube-node-lease
                - default
                - kyverno
                - cert-manager
                - ingress-nginx
                - tipsbank-monitoring
      generate:
        kind: NetworkPolicy
        apiVersion: networking.k8s.io/v1
        name: default-deny
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes: [Ingress, Egress]
```

### Arquivo: `k8s/semana4/45-kyverno-validate-registry.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: allowed-image-registries
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-registry
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Imagem fora dos registries confiaveis (zenardi/*, gcr.io/distroless/*, registry.k8s.io/*, quay.io/jetstack/*, quay.io/kyverno/*, ghcr.io/kyverno/*)."
        pattern:
          spec:
            containers:
              - name: "*"
                image: "zenardi/* | gcr.io/distroless/* | registry.k8s.io/* | quay.io/jetstack/* | quay.io/kyverno/* | ghcr.io/kyverno/* | nginxinc/nginx-unprivileged:* | postgres:*"
```

> Ajuste a lista de registries permitidos se você publicar suas imagens em outro lugar (ex.: `ghcr.io/zenardi/*` ou ECR `<account>.dkr.ecr.<region>.amazonaws.com/*`).

### Aplicar e validar

```bash
kubectl apply -f k8s/semana4/44-kyverno-generate-netpol.yaml
kubectl apply -f k8s/semana4/45-kyverno-validate-registry.yaml

# Teste do Generate — criar ns novo deve gerar a NetworkPolicy
kubectl create namespace teste-deny
kubectl get netpol -n teste-deny
# Esperado: default-deny criada automaticamente

kubectl delete namespace teste-deny

# Teste do Validate Registry — deve ser BLOQUEADO
kubectl run ruim-registry --image=docker.io/library/nginx:1.27 --dry-run=server
# Esperado: admission webhook denied
```

---

## Etapa 4.4 — RBAC: 4 perfis com certificados X.509

### O que entrega

| Usuário | Tipo | Permissões |
|---------|------|-----------|
| `operador-contas` | Role | `get/list/watch` em `pods` e `pods/log` no ns `tipsbank-contas` |
| `operador-transacoes` | Role | `get/list/watch/exec` em `pods` no ns `tipsbank-transacoes` |
| `auditor-global` | ClusterRole | `get/list/watch` em `pods` e `pods/log` em **todos** os namespaces |
| `sre` | ClusterRoleBinding em `cluster-admin` | total |

Mais **2 ServiceAccounts com Token** para uso programático.

### KIND vs EKS — diferença fundamental

| Ambiente | Como gerar o certificado do usuário |
|---|---|
| **KIND** | Acessar a CA do cluster (`/etc/kubernetes/pki/ca.{crt,key}` no nó control-plane) ou usar `CertificateSigningRequest` (CSR) com `signerName: kubernetes.io/kube-apiserver-client` — recomendado o CSR. |
| **EKS** | A chave privada da CA **não é exposta**. Use `CertificateSigningRequest` com `signerName: kubernetes.io/kube-apiserver-client` (EKS aprova após approve manual). Para usuários "humanos reais" no EKS, o caminho idiomático é **IAM via aws-auth** — mas para o desafio (que pede X.509), o CSR atende. |

### Passo 1: Gerar chave + CSR para cada usuário

Execute para cada usuário (`operador-contas`, `operador-transacoes`, `auditor-global`, `sre`):

```bash
mkdir -p evidencias/rbac/{keys,csr,certs,kubeconfigs}
echo "evidencias/rbac/keys/" >> .gitignore   # NUNCA commitar chaves privadas

USER=operador-contas

# 1. Chave privada
openssl genrsa -out evidencias/rbac/keys/${USER}.key 2048

# 2. CSR (CN = nome do usuario, O = grupo opcional)
openssl req -new -key evidencias/rbac/keys/${USER}.key \
  -out evidencias/rbac/csr/${USER}.csr \
  -subj "/CN=${USER}/O=tipsbank"
```

Repita para os 4 usuários alterando `USER=`.

### Passo 2: Criar e aprovar o CertificateSigningRequest

Para cada usuário:

```bash
USER=operador-contas
CSR_B64=$(cat evidencias/rbac/csr/${USER}.csr | base64 | tr -d '\n')

cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER}
spec:
  request: ${CSR_B64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 7776000   # 90 dias
  usages: [client auth]
EOF

# Aprovar
kubectl certificate approve ${USER}

# Extrair o certificado assinado
kubectl get csr ${USER} -o jsonpath='{.status.certificate}' | base64 -d > evidencias/rbac/certs/${USER}.crt
```

Repita para os 4 usuários.

### Passo 3: Roles e RoleBindings

Crie `k8s/semana4/rbac/50-roles.yaml`:

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: tipsbank-contas
rules:
  - apiGroups: [""]
    resources: [pods, pods/log]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: operador-contas-binding
  namespace: tipsbank-contas
subjects:
  - kind: User
    name: operador-contas
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-operator
  namespace: tipsbank-transacoes
rules:
  - apiGroups: [""]
    resources: [pods, pods/log]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [pods/exec]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: operador-transacoes-binding
  namespace: tipsbank-transacoes
subjects:
  - kind: User
    name: operador-transacoes
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-operator
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: auditor-readonly
rules:
  - apiGroups: [""]
    resources: [pods, pods/log, namespaces, services, configmaps]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, daemonsets]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: auditor-global-binding
subjects:
  - kind: User
    name: auditor-global
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: auditor-readonly
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sre-admin-binding
subjects:
  - kind: User
    name: sre
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

### Passo 4: Gerar kubeconfigs

Use o script abaixo (gera 4 arquivos `evidencias/rbac/kubeconfigs/<user>.kubeconfig`):

```bash
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

for USER in operador-contas operador-transacoes auditor-global sre; do
  KCFG="evidencias/rbac/kubeconfigs/${USER}.kubeconfig"
  CRT_B64=$(base64 -w0 evidencias/rbac/certs/${USER}.crt)
  KEY_B64=$(base64 -w0 evidencias/rbac/keys/${USER}.key)

  cat > $KCFG <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_DATA}
users:
  - name: ${USER}
    user:
      client-certificate-data: ${CRT_B64}
      client-key-data: ${KEY_B64}
contexts:
  - name: ${USER}@${CLUSTER_NAME}
    context:
      cluster: ${CLUSTER_NAME}
      user: ${USER}
current-context: ${USER}@${CLUSTER_NAME}
EOF
done
```

### Passo 5: ServiceAccounts com Token

Crie `k8s/semana4/rbac/51-serviceaccounts.yaml`:

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-contas-sa
  namespace: tipsbank-contas
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: monitoring-reader-sa
  namespace: tipsbank-monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: monitoring-reader-binding
subjects:
  - kind: ServiceAccount
    name: monitoring-reader-sa
    namespace: tipsbank-monitoring
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
---
# Token estatico para a SA monitoring-reader-sa (Day-18)
apiVersion: v1
kind: Secret
metadata:
  name: monitoring-reader-token
  namespace: tipsbank-monitoring
  annotations:
    kubernetes.io/service-account.name: monitoring-reader-sa
type: kubernetes.io/service-account-token
```

### Aplicar e validar

```bash
kubectl apply -f k8s/semana4/rbac/50-roles.yaml
kubectl apply -f k8s/semana4/rbac/51-serviceaccounts.yaml

# Criterio de aceite — colar cada saida em EVIDENCIAS.md
KC=evidencias/rbac/kubeconfigs

# operador-contas
kubectl --kubeconfig=$KC/operador-contas.kubeconfig get pods -n tipsbank-contas      # 200 ok
kubectl --kubeconfig=$KC/operador-contas.kubeconfig get pods -n tipsbank-transacoes  # FORBIDDEN

# auditor-global
kubectl --kubeconfig=$KC/auditor-global.kubeconfig get pods -A                       # lista todos
kubectl --kubeconfig=$KC/auditor-global.kubeconfig delete pod -n tipsbank-contas $(kubectl get pod -n tipsbank-contas -l app=api-contas -o name | head -1)   # FORBIDDEN

# sre
kubectl --kubeconfig=$KC/sre.kubeconfig get nodes                                    # ok

# Token da SA
kubectl get secret monitoring-reader-token -n tipsbank-monitoring -o jsonpath='{.data.token}' | base64 -d
```

> **EKS — observação adicional**: para que `kubectl --kubeconfig=<x>.kubeconfig` funcione contra o EKS, o usuário X.509 precisa estar mapeado no `aws-auth` ConfigMap **OU** o cluster precisa estar com `authentication-mode=API_AND_CONFIGMAP`. Em EKS recente (>= 1.30) o caminho recomendado é **EKS Access Entries** — mas para o desafio o CSR + RoleBinding por nome do CN basta na prática, desde que a chamada chegue no API server (cuidado com CA no kubeconfig — use o endpoint do EKS como `server:`).

---

## Etapa 4.5 — Helm Chart umbrella

### O que entrega

`helm install tipsbank ...` num cluster **vazio** sobe app + monitoring + policies + RBAC.

### Estrutura do chart

```
helm/tipsbank/
├── Chart.yaml
├── values.yaml
├── values-dev.yaml
├── values-prod.yaml
├── templates/
│   ├── _helpers.tpl
│   ├── 00-namespaces.yaml
│   ├── contas/
│   │   ├── secret.yaml
│   │   ├── configmap.yaml
│   │   ├── postgres-statefulset.yaml
│   │   ├── postgres-replica-statefulset.yaml
│   │   ├── api-deployment.yaml
│   │   ├── api-service.yaml
│   │   ├── api-hpa.yaml
│   │   ├── api-servicemonitor.yaml
│   │   └── netpol.yaml
│   ├── transacoes/
│   │   ├── secret.yaml
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml          # com sidecar log-forwarder
│   │   ├── service.yaml
│   │   ├── deployment-v2.yaml       # canary opcional (if .Values.canary.enabled)
│   │   ├── ingress.yaml
│   │   ├── ingress-canary.yaml
│   │   ├── hpa.yaml
│   │   ├── servicemonitor.yaml
│   │   └── netpol.yaml
│   ├── auditoria/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── pvc.yaml
│   │   ├── hpa.yaml
│   │   ├── servicemonitor.yaml
│   │   └── netpol.yaml
│   ├── web/
│   │   ├── configmap-nginx.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── ingress.yaml
│   │   └── netpol.yaml
│   ├── monitoring/
│   │   ├── prometheusrule.yaml
│   │   └── grafana-ingress.yaml
│   ├── rbac/
│   │   ├── roles.yaml
│   │   └── serviceaccounts.yaml
│   ├── policies/
│   │   ├── kyverno-validate-no-root.yaml
│   │   ├── kyverno-validate-no-latest.yaml
│   │   ├── kyverno-validate-require-labels.yaml
│   │   ├── kyverno-mutate-securitycontext.yaml
│   │   ├── kyverno-generate-netpol.yaml
│   │   └── kyverno-validate-registry.yaml
│   └── daemonset/
│       └── node-collector.yaml
```

> Os charts pesados (`kube-prometheus-stack`, `cert-manager`, `kyverno`, `ingress-nginx`) **NÃO** entram como subchart do umbrella — eles são pré-requisitos instalados antes via `helm install` próprio. A umbrella só cuida do que é TipsBank.

### `Chart.yaml`

```yaml
apiVersion: v2
name: tipsbank
description: TipsBank — banco digital ficticio (Desafio Final DK8s 2025)
type: application
version: 1.0.0
appVersion: "1.2.0"
maintainers:
  - name: Eduardo Zenardi
    email: du.zenardi@gmail.com
```

### `values.yaml` (defaults sensatos)

```yaml
global:
  imageRegistry: zenardi
  imagePullPolicy: IfNotPresent
  ingressClass: nginx
  clusterIssuer: tipsbank-issuer
  storageClass: ""           # vazio = default (KIND usa local-path)
  domain: tipsbank.local
  team: tipsbank
  env: lab

namespaces:
  create: true
  list:
    - tipsbank-contas
    - tipsbank-transacoes
    - tipsbank-auditoria
    - tipsbank-web
    - tipsbank-monitoring

contas:
  api:
    image: zenardi/tipsbank-api-contas
    tag: v1.1.0
    replicas: 2
    resources:
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 500m, memory: 256Mi }
    hpa:
      enabled: true
      min: 2
      max: 10
      cpuTarget: 70
  postgres:
    image: postgres
    tag: 16-alpine
    replica:
      enabled: true
    storage: 2Gi
    user: tipsbank
    db: tipsbank
    # password e injetada via --set ou values-prod.yaml — NUNCA commitar

transacoes:
  api:
    image: zenardi/tipsbank-api-transacoes
    tag: v1.2.0
    replicas: 2
    resources:
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 500m, memory: 256Mi }
    hpa:
      enabled: true
      min: 3
      max: 15
      cpuTarget: 70
  canary:
    enabled: false
    image: zenardi/tipsbank-api-transacoes
    tag: v2.0.0
    weight: 10

auditoria:
  image: zenardi/tipsbank-auditoria
  tag: v1.1.0
  replicas: 3                # KIND deve usar replicas=1 via values-dev.yaml
  storage:
    accessModes: [ReadWriteMany]
    size: 5Gi
  hpa:
    enabled: true
    min: 2
    max: 6
    memoryTarget: 75

web:
  image: zenardi/tipsbank-web
  tag: v1.0.0
  replicas: 2
  ingress:
    enabled: true
    host: app.tipsbank.local
    tls: true

monitoring:
  prometheusRule:
    enabled: true
  grafanaIngress:
    enabled: true
    host: grafana.tipsbank.local

policies:
  enabled: true              # toda a Etapa 4.1, 4.2, 4.3
  registries:
    - "zenardi/*"
    - "gcr.io/distroless/*"
    - "registry.k8s.io/*"
    - "quay.io/jetstack/*"
    - "quay.io/kyverno/*"
    - "ghcr.io/kyverno/*"
    - "nginxinc/nginx-unprivileged:*"
    - "postgres:*"

rbac:
  enabled: true
```

### `values-dev.yaml` (KIND)

```yaml
global:
  env: dev
  storageClass: standard

contas:
  postgres:
    storage: 1Gi
auditoria:
  replicas: 1
  storage:
    accessModes: [ReadWriteOnce]
    size: 1Gi
transacoes:
  api:
    replicas: 2
    hpa: { min: 2, max: 5 }
```

### `values-prod.yaml` (EKS)

```yaml
global:
  env: prod
  storageClass: gp3

contas:
  api:
    replicas: 3
    hpa: { min: 3, max: 12 }
  postgres:
    storage: 20Gi

transacoes:
  api:
    replicas: 3
    hpa: { min: 3, max: 20 }
  canary:
    enabled: true
    weight: 10

auditoria:
  replicas: 3
  storage:
    accessModes: [ReadWriteMany]
    size: 20Gi
```

### `_helpers.tpl` (essenciais)

```gotemplate
{{- define "tipsbank.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tipsbank.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
team: {{ .Values.global.team }}
env: {{ .Values.global.env }}
{{- end -}}

{{- define "tipsbank.image" -}}
{{- printf "%s:%s" .image .tag -}}
{{- end -}}
```

### Passo 1: Criar os arquivos do chart

```bash
mkdir -p helm/tipsbank/templates/{contas,transacoes,auditoria,web,monitoring,rbac,policies,daemonset}
# preencher conforme estrutura acima — port direto dos manifests existentes,
# trocando valores hardcoded por {{ .Values.* }}
```

> **Estratégia recomendada de migração**: pegue cada YAML de `k8s/semana1/`, `k8s/semana2/`, `k8s/semana3/` e `k8s/semana4/` e templatize só os campos que variam por ambiente (imagem/tag, réplicas, recursos, storage, host). Comece simples, evolua.

### Passo 2: Lint e render

```bash
helm lint helm/tipsbank/
helm lint helm/tipsbank/ -f helm/tipsbank/values-prod.yaml

# Renderizar para inspecao
helm template tipsbank helm/tipsbank/ -f helm/tipsbank/values-dev.yaml | head -60
helm template tipsbank helm/tipsbank/ -f helm/tipsbank/values-prod.yaml > /tmp/render-prod.yaml
```

### Passo 3: Instalar num cluster LIMPO

> **Importante**: pré-requisitos (cert-manager, ingress-nginx, kube-prometheus-stack, kyverno) são instalados antes. O `tipsbank` umbrella usa esses recursos mas não os instala.

```bash
# 1. Pre-requisitos (KIND ou EKS)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml   # KIND
# OU EKS:
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace --wait

helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true --wait
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n tipsbank-monitoring --create-namespace --wait \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false

# 2. Instalar o umbrella TipsBank
# KIND
helm install tipsbank helm/tipsbank/ -f helm/tipsbank/values-dev.yaml \
  --set contas.postgres.password=tipsbank \
  --create-namespace

# EKS
helm install tipsbank helm/tipsbank/ -f helm/tipsbank/values-prod.yaml \
  --set contas.postgres.password="$(openssl rand -hex 16)" \
  --create-namespace

# 3. Esperar tudo subir
kubectl get pods -A -w
```

### Passo 4: Publicar o chart num repositório remoto

#### Opção A — GitHub Pages (recomendado para o desafio)

```bash
# No repo de chart (pode ser este mesmo)
helm package helm/tipsbank/ -d /tmp/charts/
helm repo index /tmp/charts/ --url https://zenardi.github.io/dk8s-charts/
# commit /tmp/charts/* num branch gh-pages
```

#### Opção B — OCI no ghcr.io

```bash
helm package helm/tipsbank/ -d /tmp/
helm registry login ghcr.io -u zenardi
helm push /tmp/tipsbank-1.0.0.tgz oci://ghcr.io/zenardi/charts
```

### Passo 5: Testar upgrade e rollback

```bash
# Mudar a tag de uma API e fazer upgrade
helm upgrade tipsbank helm/tipsbank/ -f helm/tipsbank/values-dev.yaml \
  --set contas.api.tag=v1.1.1

helm history tipsbank
helm rollback tipsbank 1
```

### Critérios de aceite

```bash
helm lint helm/tipsbank/                                                # zero erros
helm template tipsbank helm/tipsbank/ > /dev/null                       # render ok
helm install tipsbank helm/tipsbank/ -f helm/tipsbank/values-dev.yaml   # cluster limpo, < 10min
kubectl get pods -A | grep tipsbank | grep -v Running | grep -v Completed   # vazio
helm upgrade tipsbank helm/tipsbank/ --set contas.api.tag=v1.1.1        # sem downtime
helm rollback tipsbank 1                                                # rollback ok
helm list -A | grep tipsbank
```

---

## Etapa 4.6 — Teste de compliance final

### Script: `scripts/compliance-check.sh`

```bash
#!/usr/bin/env bash
# Roda os 7 checks de compliance do MANUAL-ALUNO.md e gera saida para EVIDENCIAS.md.
set -uo pipefail

REGISTRY_REGEX='ghcr.io/zenardi|zenardi/|quay.io/jetstack|registry.k8s.io|gcr.io/distroless|quay.io/kyverno|ghcr.io/kyverno|nginxinc/nginx-unprivileged|postgres:'

echo "================================================================"
echo "TipsBank — Compliance Check  ($(date -u +%FT%TZ))"
echo "================================================================"

echo
echo "## 1. Imagens FORA do registry confiavel (deve ser vazio)"
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | grep -v -E "$REGISTRY_REGEX" || echo "(vazio — OK)"

echo
echo "## 2. Pods rodando como root (deve ser vazio)"
kubectl get pods -A -o json | jq '[.items[] | select(.spec.securityContext.runAsUser == 0 or (.spec.containers[].securityContext.runAsUser // 1) == 0) | "\(.metadata.namespace)/\(.metadata.name)"]'

echo
echo "## 3. Workloads SEM livenessProbe (deve ser vazio para tipsbank-*)"
kubectl get deploy,sts,ds -A -o json \
  | jq '[.items[] | select(.metadata.namespace | startswith("tipsbank")) | select(.spec.template.spec.containers[].livenessProbe == null) | "\(.metadata.namespace)/\(.metadata.name)"]'

echo
echo "## 4. Workloads SEM resources.limits (deve ser vazio para tipsbank-*)"
kubectl get deploy,sts,ds -A -o json \
  | jq '[.items[] | select(.metadata.namespace | startswith("tipsbank")) | select(.spec.template.spec.containers[].resources.limits == null) | "\(.metadata.namespace)/\(.metadata.name)"]'

echo
echo "## 5. Policies Kyverno ativas"
kubectl get cpol -o json | jq '.items[] | {name: .metadata.name, ready: .status.ready}'

echo
echo "## 6. NetworkPolicies por namespace"
for ns in tipsbank-contas tipsbank-transacoes tipsbank-auditoria tipsbank-web; do
  echo "### $ns"
  kubectl get netpol -n $ns
done

echo
echo "## 7. Imagens assinadas (Cosign)"
for img in zenardi/tipsbank-api-contas:v1.1.0 \
           zenardi/tipsbank-api-transacoes:v1.2.0 \
           zenardi/tipsbank-auditoria:v1.1.0 \
           zenardi/tipsbank-web:v1.0.0; do
  if cosign verify $img \
       --certificate-identity-regexp '.*' \
       --certificate-oidc-issuer-regexp '.*' >/dev/null 2>&1; then
    echo "OK: $img"
  else
    echo "FAIL: $img"
  fi
done

echo
echo "================================================================"
echo "Fim do compliance check."
```

### Rodar e capturar evidência

```bash
chmod +x scripts/compliance-check.sh
./scripts/compliance-check.sh | tee evidencias/compliance-$(date +%Y%m%d-%H%M).log
```

### Tentativas que DEVEM ser bloqueadas (gravar em `EVIDENCIAS.md`)

```bash
# 1. Pod com :latest
kubectl run ruim-1 --image=nginx:latest 2>&1 | tee -a EVIDENCIAS.md

# 2. Pod como root
cat <<EOF | kubectl apply -f - 2>&1 | tee -a EVIDENCIAS.md
apiVersion: v1
kind: Pod
metadata: { name: ruim-2, namespace: default }
spec:
  securityContext: { runAsUser: 0 }
  containers:
    - { name: c, image: nginx:1.27 }
EOF

# 3. Deployment sem labels app/team/env
cat <<EOF | kubectl apply -f - 2>&1 | tee -a EVIDENCIAS.md
apiVersion: apps/v1
kind: Deployment
metadata: { name: ruim-3, namespace: default, labels: { app: ruim } }
spec:
  replicas: 1
  selector: { matchLabels: { app: ruim } }
  template:
    metadata: { labels: { app: ruim } }
    spec:
      containers: [{ name: c, image: nginx:1.27 }]
EOF
```

### Critérios de aceite

- Script `compliance-check.sh` roda limpo (todos os checks 1–7 sem violação).
- 3 tentativas acima rejeitadas pelo Kyverno e mensagens coladas em `EVIDENCIAS.md`.
- Nuance do `web` (nonroot/minimal, não Distroless puro) documentada em `EVIDENCIAS.md` (já está no MANUAL-ALUNO Etapa 4.6).

---

## Etapa 4.7 — Vídeo demo final

Sem mudança de cluster — só roteiro. Crie `docs/ROTEIRO-VIDEO.md`:

```markdown
# Roteiro do video (10–15 min)

## 0–1min — Intro
- Quem sou, qual o desafio, o que vai mostrar.

## 1–3min — Cluster limpo + helm install
- `kind delete cluster --name tipsbank` (ou `eksctl delete cluster`) e recriar.
- `helm install tipsbank ...`
- `kubectl get pods -A --watch` ate tudo Running.

## 3–5min — App funcionando
- Abrir `https://app.tipsbank.local` no browser.
- Login com 12345678901 / giropops.
- Fazer uma transferencia R$ 100. Mostrar no extrato.

## 5–7min — Observabilidade
- Grafana > dashboard com requests, latencia, CPU.
- Prometheus > targets UP.
- Alertmanager > vista geral.

## 7–9min — Locust + HPA
- Iniciar load (200 users) no `https://locust.tipsbank.local`.
- Mostrar `kubectl get hpa -A -w` escalando.
- Mostrar grafico de CPU/replicas no Grafana.

## 9–11min — Kyverno bloqueando
- `kubectl run ruim --image=nginx:latest` > BLOQUEADO.
- `kubectl run --image=nginx:1.27 --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' ruim2` > BLOQUEADO.

## 11–12min — Canary 90/10
- 100 requests para `/transacoes/health/live` mostrando ~90 v1 / ~10 v2.

## 12–13min — RBAC
- `kubectl --kubeconfig=auditor-global.kubeconfig get pods -A` > ok.
- `kubectl --kubeconfig=auditor-global.kubeconfig delete pod X` > FORBIDDEN.
- `kubectl --kubeconfig=operador-contas.kubeconfig get pods -n tipsbank-transacoes` > FORBIDDEN.

## 13–14min — Rollback
- `helm upgrade tipsbank --set contas.api.tag=v1.1.1`
- `helm rollback tipsbank 1`

## 14–15min — Encerramento
- `helm uninstall tipsbank` mostrando recursos sendo limpos.
- Agradecimento.
```

### Critérios de aceite

- Vídeo publicado (YouTube unlisted ou Loom).
- Os 10 pontos do MANUAL-ALUNO Etapa 4.7 aparecem.
- Áudio audível, narração clara.

---

## Resumo dos arquivos criados nesta Semana

```
k8s/semana4/
├── 40-kyverno-validate-no-root.yaml
├── 41-kyverno-validate-no-latest.yaml
├── 42-kyverno-validate-require-labels.yaml
├── 43-kyverno-mutate-securitycontext.yaml
├── 44-kyverno-generate-netpol.yaml
├── 45-kyverno-validate-registry.yaml
└── rbac/
    ├── 50-roles.yaml
    └── 51-serviceaccounts.yaml

helm/tipsbank/
├── Chart.yaml
├── values.yaml
├── values-dev.yaml
├── values-prod.yaml
└── templates/...   (estrutura completa na Etapa 4.5)

scripts/
└── compliance-check.sh

docs/
└── ROTEIRO-VIDEO.md

evidencias/
├── rbac/
│   ├── keys/             (NAO commitar — adicionar no .gitignore)
│   ├── csr/
│   ├── certs/
│   └── kubeconfigs/
└── compliance-*.log
```

---

## Ordem recomendada de aplicação (cluster vazio)

```bash
# Pre-requisitos: subir Semanas 1, 2 e 3 conforme PLAN-SEMANA-3.md
# (cluster KIND ou EKS, app rodando, Ingress/TLS, NetPol, kube-prometheus, HPA, Locust)

# === SEMANA 4 ===

# Etapa 4.1 — Kyverno + Validate
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

# Adicionar labels team/env nos workloads existentes (ver Passo 2 da Etapa 4.1)
for ns in tipsbank-contas tipsbank-transacoes tipsbank-auditoria tipsbank-web; do
  kubectl get deploy,sts -n $ns -o name | xargs -I{} kubectl label -n $ns {} team=tipsbank env=lab --overwrite
done

kubectl apply -f k8s/semana4/40-kyverno-validate-no-root.yaml
kubectl apply -f k8s/semana4/41-kyverno-validate-no-latest.yaml
kubectl apply -f k8s/semana4/42-kyverno-validate-require-labels.yaml

# Etapa 4.2 — Mutate
kubectl apply -f k8s/semana4/43-kyverno-mutate-securitycontext.yaml

# Etapa 4.3 — Generate + Registry
kubectl apply -f k8s/semana4/44-kyverno-generate-netpol.yaml
kubectl apply -f k8s/semana4/45-kyverno-validate-registry.yaml

# Etapa 4.4 — RBAC
# (gerar keys/CSR/certs/kubeconfigs conforme Passos 1–4)
kubectl apply -f k8s/semana4/rbac/50-roles.yaml
kubectl apply -f k8s/semana4/rbac/51-serviceaccounts.yaml

# Etapa 4.5 — Helm umbrella (instalacao a partir de cluster LIMPO)
# (ver secao dedicada — supoe pre-requisitos instalados antes)
helm install tipsbank helm/tipsbank/ -f helm/tipsbank/values-dev.yaml    # KIND
# OU
helm install tipsbank helm/tipsbank/ -f helm/tipsbank/values-prod.yaml   # EKS

# Etapa 4.6 — Compliance final
./scripts/compliance-check.sh | tee evidencias/compliance-$(date +%Y%m%d-%H%M).log
```

---

## Checkpoint final — Semana 4

```bash
# 1. Kyverno policies — 6 ClusterPolicies READY
kubectl get cpol
# Esperado: 6 entradas, todas READY=true

# 2. Mutate funcionando
kubectl run check-mutate --image=nginx:1.27 --restart=Never --command -- sleep 30
kubectl get pod check-mutate -o jsonpath='{.spec.containers[0].securityContext}{"\n"}'
kubectl delete pod check-mutate
# Esperado: campos runAsNonRoot, readOnlyRootFilesystem, allowPrivilegeEscalation injetados

# 3. Generate funcionando
kubectl create namespace check-gen
kubectl get netpol -n check-gen
kubectl delete namespace check-gen
# Esperado: NetworkPolicy default-deny criada automaticamente

# 4. Registry policy bloqueando
kubectl run check-bad-registry --image=docker.io/library/nginx:1.27 2>&1 | grep -i denied
# Esperado: admission webhook denied

# 5. RBAC — 4 perfis funcionando
KC=evidencias/rbac/kubeconfigs
kubectl --kubeconfig=$KC/operador-contas.kubeconfig get pods -n tipsbank-contas      # OK
kubectl --kubeconfig=$KC/operador-contas.kubeconfig get pods -n tipsbank-transacoes  # FORBIDDEN
kubectl --kubeconfig=$KC/operador-transacoes.kubeconfig auth can-i create pods/exec -n tipsbank-transacoes   # yes
kubectl --kubeconfig=$KC/auditor-global.kubeconfig get pods -A                       # OK
kubectl --kubeconfig=$KC/auditor-global.kubeconfig auth can-i delete pods -A         # no
kubectl --kubeconfig=$KC/sre.kubeconfig auth can-i '*' '*' --all-namespaces          # yes

# 6. ServiceAccounts com Token
kubectl get sa -A | grep -E "api-contas-sa|monitoring-reader-sa"
kubectl get secret monitoring-reader-token -n tipsbank-monitoring -o jsonpath='{.data.token}' | base64 -d > /dev/null && echo "token ok"

# 7. Helm Chart
helm lint helm/tipsbank/                                                   # 0 erros
helm template tipsbank helm/tipsbank/ -f helm/tipsbank/values-dev.yaml > /dev/null
helm template tipsbank helm/tipsbank/ -f helm/tipsbank/values-prod.yaml > /dev/null
helm list -A | grep tipsbank                                               # release ativa
helm history tipsbank                                                      # >= 2 revisoes apos upgrade+rollback

# 8. App ainda funcional (smoke test)
curl -sk https://app.tipsbank.local/ | grep -i tipsbank
curl -sk https://api.tipsbank.local/contas/health/live
curl -sk https://api.tipsbank.local/transacoes/health/live
curl -sk https://api.tipsbank.local/auditoria/health/live

# 9. Compliance final — script todo OK
./scripts/compliance-check.sh

# 10. Video
ls docs/ROTEIRO-VIDEO.md
echo "Link do video final: <preencher em EVIDENCIAS.md>"
```

### Checklist final (todas as 4 semanas)

- [X] 4 imagens (3 APIs Distroless + `web` nonroot/minimal) Trivy clean + Cosign
- [X] Cluster kubeadm/KIND 3-nodes **OU** EKS funcional
- [X] Helm Chart umbrella instala tudo num cluster limpo em < 10 min
- [X] 6 Kyverno ClusterPolicies (3 Validate + 1 Mutate + 1 Generate + 1 Registry)
- [X] 4 perfis RBAC com X.509 + 2 ServiceAccounts com Token validados
- [X] NetworkPolicy default-deny em todos os ns `tipsbank-*`
- [X] kube-prometheus-stack + 4 alertas + dashboards
- [X] 3 HPAs + Locust 200 users + escala observada
- [X] Canary 90/10 entre v1 e v2
- [X] `EVIDENCIAS.md` com saidas dos 7 checks de compliance + 3 rejeicoes do Kyverno
- [X] Video demo final publicado e linkado em `EVIDENCIAS.md`

---

**Pronto. Submissao final do TipsBank.**
