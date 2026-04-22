# TipsBank — Roteiro de Gravação: Semana 1

> Script de referência para a gravação do vídeo de entrega da Semana 1.
> Tudo já foi validado offline. Durante a gravação, apenas copie e cole.

---

## 🔧 Antes de começar — defina as variáveis

```bash
export REGISTRY="zenardi"
export TAG="v1.0.0"
export CP_IP="192.168.56.10"              # IP do control-plane
export W1_IP="192.168.56.11"              # IP do worker1 (também será o NFS server)
export W2_IP="192.168.56.12"              # IP do worker2
export NFS_SERVER_IP="${W1_IP}"
export KUBECONFIG=~/Documents/develop/DescomplicandoKubernetes/desafios/tipsbank/vagrant/admin.conf
```

---

## Etapa 1.1 — App rodando localmente

```bash
# Subir a stack completa
cd tipsbank
docker compose up --build -d

# Aguardar serviços ficarem saudáveis
docker compose ps

# ✅ critério: listar contas seed (sem senha_hash exposto)
curl -s http://localhost:8081/contas | jq

# ✅ critério: login com senha correta → 200
curl -s -X POST http://localhost:8081/login \
  -H 'content-type: application/json' \
  -d '{"documento":"12345678901","senha":"giropops"}' | jq

# ✅ critério: login com senha errada → 401
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST http://localhost:8081/login \
  -H 'content-type: application/json' \
  -d '{"documento":"12345678901","senha":"errada"}'

# ✅ critério: transferência altera saldo de ambas as contas
# saldo antes
curl -s http://localhost:8081/contas/11111111-1111-1111-1111-111111111111 | jq .saldo
curl -s http://localhost:8081/contas/22222222-2222-2222-2222-222222222222 | jq .saldo

curl -s -X POST http://localhost:8082/transferencias \
  -H 'content-type: application/json' \
  -d '{"origem_id":"11111111-1111-1111-1111-111111111111","destino_id":"22222222-2222-2222-2222-222222222222","valor":"100.00"}' | jq

# saldo depois
curl -s http://localhost:8081/contas/11111111-1111-1111-1111-111111111111 | jq .saldo
curl -s http://localhost:8081/contas/22222222-2222-2222-2222-222222222222 | jq .saldo

# ✅ critério: arquivo de auditoria com eventos
docker exec tipsbank-auditoria ls /data
docker exec tipsbank-auditoria cat /data/eventos-$(date +%Y-%m-%d).jsonl | jq

# ✅ critério: health checks de todos os serviços
curl -s http://localhost:8081/health/live
curl -s http://localhost:8082/health/live
curl -s http://localhost:8083/health/live
curl -s http://localhost:8080/healthz

# SPA disponível em http://localhost:8080 — mostrar no browser durante a gravação
echo "Abrir http://localhost:8080 no browser"

docker compose down
```

---

## Etapa 1.2 — Build Distroless, Trivy e Cosign

```bash
cd tipsbank

# --- Build das 4 imagens ---
docker build -t ${REGISTRY}/tipsbank-api-contas:${TAG}     apps/api-contas
docker build -t ${REGISTRY}/tipsbank-api-transacoes:${TAG} apps/api-transacoes
docker build -t ${REGISTRY}/tipsbank-auditoria:${TAG}      apps/auditoria
docker build -t ${REGISTRY}/tipsbank-web:${TAG}            apps/web

# --- Scan com Trivy (deve retornar 0 HIGH/CRITICAL) ---
# ✅ critério: trivy devolve 0 vulnerabilidades HIGH ou CRITICAL
for app in api-contas api-transacoes auditoria web; do
  echo "=== Trivy: tipsbank-${app} ==="
  trivy image --severity HIGH,CRITICAL --exit-code 1 ${REGISTRY}/tipsbank-${app}:${TAG}
done

# --- Comando com export para arquivo ---
set -o pipefail
for app in api-contas api-transacoes auditoria web; do
  echo "=== Trivy: tipsbank-${app} ==="
  trivy image --severity HIGH,CRITICAL --exit-code 1 \
    ${REGISTRY}/tipsbank-${app}:${TAG} | tee ./trivy-${app}.txt
done


# --- Docker Scout (complementar) ---
for app in api-contas api-transacoes auditoria web; do
  echo "=== Scout: tipsbank-${app} ==="
  docker scout cves ${REGISTRY}/tipsbank-${app}:${TAG} || true
done

# --- Verificar usuário não-root ---
# ✅ critério: APIs com UID 65532, web com UID 101
docker inspect ${REGISTRY}/tipsbank-api-contas:${TAG} | jq '.[0].Config.User'
docker inspect ${REGISTRY}/tipsbank-web:${TAG}        | jq '.[0].Config.User'

# Tamanhos das imagens
# ✅ critério: APIs < 150 MB, web < 30 MB
docker images | grep tipsbank

# --- Push para o registry ---
for app in api-contas api-transacoes auditoria web; do
  docker push ${REGISTRY}/tipsbank-${app}:${TAG}
done

# --- Assinar com Cosign (keyless OIDC) ---
for app in api-contas api-transacoes auditoria web; do
  echo "=== Assinando: tipsbank-${app} ==="
  COSIGN_EXPERIMENTAL=1 cosign sign --yes ${REGISTRY}/tipsbank-${app}:${TAG}
done

# --- Verificar assinaturas ---
# ✅ critério: cosign verify passa nas 4 imagens
for app in api-contas api-transacoes auditoria web; do
  echo "=== Verificando: tipsbank-${app} ==="
  COSIGN_EXPERIMENTAL=1 cosign verify \
    --certificate-identity-regexp '.*' \
    --certificate-oidc-issuer-regexp '.*' \
    ${REGISTRY}/tipsbank-${app}:${TAG} \
    | jq '.[0].optional.subject'
done
```

---

## Etapa 1.3 — Cluster kubeadm (1 CP + 2 Workers) com Cilium

> Cluster provisionado via **Vagrant** (VirtualBox). Todos os scripts estão em `vagrant/`.
> Ubuntu 22.04 | containerd | kubeadm 1.32 | **Cilium CNI** | pod-cidr: 10.0.0.0/8

### Subir o cluster completo (um comando)

```bash
cd tipsbank/vagrant
vagrant up
# ☕ Aguarde ~10-15 min — provisiona 3 VMs, instala containerd + kubeadm + Cilium automaticamente
```

### Acessar o cluster do host

```bash
# O admin.conf é exportado automaticamente para vagrant/admin.conf
export KUBECONFIG=$(pwd)/admin.conf

# Ou via SSH no control-plane
vagrant ssh controlplane
```

### Verificação do cluster

```bash
# ✅ critério: 3 nodes Ready
kubectl get nodes -o wide

# ✅ critério: todos os pods kube-system Running (incluindo Cilium)
kubectl get pods -A

# ✅ critério: Cilium healthy
cilium status

# ✅ critério: pod de teste vai para worker (não para CP — taint NoSchedule)
kubectl run nginx-teste --image=nginx --restart=Never
kubectl get pod nginx-teste -o wide   # deve mostrar worker1 ou worker2
kubectl delete pod nginx-teste
```

### Recriar o cluster do zero (se necessário)

```bash
cd tipsbank/vagrant
vagrant destroy -f && vagrant up
```

---

## Etapa 1.4 — Namespaces, Deployments, StatefulSet e Services

> Manifests em `k8s/semana1/` — numerados de 00 a 08 para garantir ordem de apply.
> Todos os `kubectl` assumem `KUBECONFIG` apontando para o cluster Vagrant.

### PRÉ-REQUISITO: StorageClass default (para o PVC do Postgres)

```bash
# local-path-provisioner fornece StorageClass "local-path" com provisioning dinâmico
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml

# Marcar como default
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# ✅ verificar: coluna DEFAULT mostra (default)
kubectl get storageclass
```

### Deploy completo

```bash
cd tipsbank

# 1. Namespaces
kubectl apply -f k8s/semana1/00-namespaces.yaml
kubectl get namespaces | grep tipsbank

# 2. Secrets e ConfigMaps
kubectl apply -f k8s/semana1/01-secret-db.yaml       # postgres-credentials em tipsbank-contas
kubectl apply -f k8s/semana1/02-configmap-init-sql.yaml
kubectl apply -f k8s/semana1/03-configmap-nginx.yaml  # nginx com FQDNs cross-namespace

# 3. Postgres StatefulSet + Headless Service (aguardar Ready antes das APIs)
kubectl apply -f k8s/semana1/04-postgres.yaml
kubectl rollout status statefulset/postgres -n tipsbank-contas --timeout=180s

# 4. api-contas (mesmo namespace do postgres — initContainer espera pg)
kubectl apply -f k8s/semana1/05-api-contas.yaml
kubectl rollout status deployment/api-contas -n tipsbank-contas --timeout=180s

# 5. api-transacoes (initContainers esperam postgres + api-contas ready)
kubectl apply -f k8s/semana1/06-api-transacoes.yaml
kubectl rollout status deployment/api-transacoes -n tipsbank-transacoes --timeout=180s

# 6. auditoria (emptyDir por enquanto — etapa 1.6 vira NFS)
kubectl apply -f k8s/semana1/07-auditoria.yaml
kubectl rollout status deployment/auditoria -n tipsbank-auditoria --timeout=120s

# 7. web (nginx com ConfigMap sobrepondo nginx.conf da imagem)
kubectl apply -f k8s/semana1/08-web.yaml
kubectl rollout status deployment/web -n tipsbank-web --timeout=120s
```

### Verificação

```bash
# ✅ critério: todos os pods Running (2/2 deployments, 1/1 STS)
kubectl get pods -A | grep tipsbank

# ✅ critério: services criados em todos os namespaces
kubectl get svc -A | grep tipsbank

# ✅ critério: PVC do postgres Bound
kubectl get pvc -n tipsbank-contas

# ✅ critério: env vars sensíveis via secretKeyRef (não em texto plano)
kubectl get deployment api-contas -n tipsbank-contas -o jsonpath='{.spec.template.spec.containers[0].env}' | jq
```

### Testes via port-forward

```bash
# --- Teste da api-contas ---
kubectl port-forward -n tipsbank-contas svc/api-contas 8081:8080 &
sleep 2
# ✅ critério: login seed funciona
curl -s -X POST http://localhost:8081/login \
  -H 'content-type: application/json' \
  -d '{"documento":"12345678901","senha":"giropops"}' | jq
kill %1

# --- Teste da api-transacoes (transferência) ---
kubectl port-forward -n tipsbank-transacoes svc/api-transacoes 8082:8080 &
sleep 2
# ✅ critério: transferência entre contas seed retorna 201
curl -s -X POST http://localhost:8082/transferencias \
  -H 'content-type: application/json' \
  -d '{"origem_id":"11111111-1111-1111-1111-111111111111","destino_id":"22222222-2222-2222-2222-222222222222","valor":"50.00"}' | jq
kill %1

# --- Teste da auditoria ---
kubectl port-forward -n tipsbank-auditoria svc/auditoria 8083:8080 &
sleep 2
# ✅ critério: evento da transferência aparece no log
curl -s http://localhost:8083/eventos | jq
kill %1

# --- Teste do frontend ---
kubectl port-forward -n tipsbank-web svc/web 8080:8080 &
echo "✅ Abrir http://localhost:8080 no browser — login: CPF 12345678901 / senha giropops"
# (parar manualmente após demonstrar no browser)
kill %1
```

---

## Etapa 1.5 — Pod multicontainer + ConfigMap/Secret

```bash
# ✅ critério: pod com 2 containers (2/2 Running)
kubectl get pods -n tipsbank-transacoes

POD_TX=$(kubectl get pod -n tipsbank-transacoes -l app=api-transacoes -o jsonpath='{.items[0].metadata.name}')
echo "Pod: ${POD_TX}"

# ✅ critério: describe mostra 2 containers (api-transacoes + log-forwarder)
kubectl describe pod ${POD_TX} -n tipsbank-transacoes | grep -A 40 "Containers:"

# ✅ critério: variáveis via secretKeyRef e configMapKeyRef — NENHUM valor sensível inline
kubectl get deployment api-transacoes -n tipsbank-transacoes -o yaml | grep -A 5 "valueFrom:"

# ✅ Secrets com nomes distintos por namespace (não compartilhados)
kubectl get secret contas-db-secret -n tipsbank-contas
kubectl get secret transacoes-db-secret -n tipsbank-transacoes

# ✅ ConfigMaps com nomes distintos por namespace
kubectl get configmap -A | grep tipsbank
kubectl describe configmap contas-app-config -n tipsbank-contas
kubectl describe configmap transacoes-app-config -n tipsbank-transacoes

# Gerar tráfego para popular o log (transferência via API)
kubectl port-forward -n tipsbank-transacoes svc/api-transacoes 18080:8080 &
sleep 2
curl -s -X POST http://localhost:18080/transferencias \
  -H "Content-Type: application/json" \
  -d '{"origem_id":"11111111-1111-1111-1111-111111111111","destino_id":"22222222-2222-2222-2222-222222222222","valor":5.0,"descricao":"demo etapa 1.5"}' | python3 -m json.tool
kill %1

# ✅ critério: sidecar log-forwarder exibe logs JSON estruturados da app
# (verificar em AMBOS os pods — o tráfego pode ter ido para qualquer um)
for pod in $(kubectl get pod -n tipsbank-transacoes -l app=api-transacoes -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $pod ===" && kubectl logs -n tipsbank-transacoes "$pod" -c log-forwarder --tail=10
done
```

---

## Etapa 1.6 — PV NFS (RWX) para a auditoria

### No worker1 — instalar e configurar NFS server

```bash
# O script setup-nfs-server.sh instala nfs-kernel-server, cria o diretório
# /srv/nfs/auditoria (chown 65532:65532) e configura /etc/exports
cd tipsbank/vagrant
vagrant ssh worker1 -- sudo bash /vagrant/scripts/setup-nfs-server.sh

# Verificar exportação
vagrant ssh worker1 -- showmount -e localhost
```

### Instalar nfs-common nos demais nodes (necessário para o kubelet montar NFS)

```bash
vagrant ssh controlplane -- sudo apt-get install -y nfs-common
vagrant ssh worker2      -- sudo apt-get install -y nfs-common
# worker1 já tem via nfs-kernel-server
```

### Aplicar PV + PVC e atualizar Deployment

```bash
cd tipsbank

# ✅ critério: PV Bound ao PVC
kubectl apply -f k8s/semana1/09-nfs.yaml
kubectl wait pvc/auditoria-nfs-pvc -n tipsbank-auditoria \
  --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pv,pvc -A | grep auditoria

# Atualizar auditoria: emptyDir → PVC NFS, replicas 2 → 3
kubectl apply -f k8s/semana1/07-auditoria.yaml
kubectl rollout status deployment/auditoria -n tipsbank-auditoria --timeout=120s

# ✅ critério: 3 réplicas Running
kubectl get pods -n tipsbank-auditoria -o wide
```

### Disparar 100 transferências e validar contagem de eventos

```bash
# Port-forward para api-transacoes
kubectl port-forward -n tipsbank-transacoes svc/api-transacoes 18080:8080 &
sleep 2

# 100 transferências alternando direção (evita zerar saldo)
for i in $(seq 1 100); do
  if [ $((i % 2)) -eq 0 ]; then
    ORIGEM="11111111-1111-1111-1111-111111111111"
    DESTINO="22222222-2222-2222-2222-222222222222"
  else
    ORIGEM="22222222-2222-2222-2222-222222222222"
    DESTINO="11111111-1111-1111-1111-111111111111"
  fi
  curl -s -o /dev/null -X POST http://localhost:18080/transferencias \
    -H "Content-Type: application/json" \
    -d "{\"origem_id\":\"${ORIGEM}\",\"destino_id\":\"${DESTINO}\",\"valor\":1.0,\"descricao\":\"etapa-1.6-test-${i}\"}"
done
kill %1

# ✅ critério: os 3 pods veem o mesmo arquivo (API /arquivos — imagem distroless, sem ls)
PODS=($(kubectl get pod -n tipsbank-auditoria -l app=auditoria -o jsonpath='{.items[*].metadata.name}'))

idx=0
for pod in "${PODS[@]}"; do
  PORT=$((19080 + idx))
  kubectl port-forward -n tipsbank-auditoria "pod/${pod}" ${PORT}:8080 &
  idx=$((idx + 1))
done
sleep 3

idx=0
for pod in "${PODS[@]}"; do
  PORT=$((19080 + idx))
  echo -n "${pod} arquivos: " && curl -s "http://localhost:${PORT}/arquivos"
  echo ""
  idx=$((idx + 1))
done

# ✅ critério: mesma contagem de eventos nos 3 pods (NFS compartilhado)
idx=0
for pod in "${PODS[@]}"; do
  PORT=$((19080 + idx))
  COUNT=$(curl -s "http://localhost:${PORT}/eventos?limit=500" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
  echo "${pod}: ${COUNT} eventos"
  idx=$((idx + 1))
done

kill $(jobs -p) 2>/dev/null; true
```

---

## ✅ Checkpoint Final — Todos os critérios da Semana 1

```bash
echo "========================================"
echo "CHECKPOINT SEMANA 1"
echo "========================================"

# 1. Cluster 3 nodes Ready
echo "--- Nodes ---"
kubectl get nodes -o wide

# 2. Todos os pods tipsbank Running
echo "--- Pods ---"
kubectl get pods -A | grep tipsbank

# 3. PV/PVC NFS Bound
echo "--- Storage ---"
kubectl get pv,pvc -A | grep -E "nfs|tipsbank"

# 4. Secrets e ConfigMaps existem nos namespaces certos
echo "--- Secrets ---"
kubectl get secrets -A | grep tipsbank
echo "--- ConfigMaps ---"
kubectl get configmap -A | grep tipsbank

# 5. Pod multicontainer (2/2) em tipsbank-transacoes
echo "--- Multicontainer ---"
kubectl get pods -n tipsbank-transacoes

# 6. Transferência end-to-end pelo K8s
echo "--- Transferência via K8s ---"
kubectl port-forward -n tipsbank-transacoes svc/api-transacoes 8082:8080 &
sleep 2
curl -s -X POST http://localhost:8082/transferencias \
  -H 'content-type: application/json' \
  -d '{"origem_id":"11111111-1111-1111-1111-111111111111","destino_id":"22222222-2222-2222-2222-222222222222","valor":"10.00"}' | jq
kill %1

# 7. Auditoria NFS: 3 réplicas veem os mesmos dados
echo "--- Auditoria NFS ---"
for p in $(kubectl get pod -n tipsbank-auditoria -l app=auditoria -o jsonpath='{.items[*].metadata.name}'); do
  echo "${p}: $(kubectl exec -n tipsbank-auditoria ${p} -- sh -c 'wc -l /data/*.jsonl 2>/dev/null | tail -1')"
done

echo "========================================"
echo "Semana 1 concluída!"
echo "========================================"
```
