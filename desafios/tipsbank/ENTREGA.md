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
export KUBECONFIG=~/.kube/config
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

> Assumindo que os manifests estão em k8s/semana1/

```bash
cd tipsbank

# Substituir o placeholder do registry nos manifests
sed -i "s|ghcr.io/SEU-USUARIO|${REGISTRY}|g" \
  k8s/semana1/contas/05-api-contas-deployment.yaml \
  k8s/semana1/transacoes/03-api-transacoes-deployment.yaml \
  k8s/semana1/auditoria/01-auditoria-deployment.yaml \
  k8s/semana1/web/02-web-deployment.yaml

# Criar namespaces
kubectl apply -f k8s/semana1/00-namespaces.yaml
kubectl get namespaces | grep tipsbank

# Namespace contas: Secret, ConfigMaps, Postgres STS, api-contas
kubectl apply -f k8s/semana1/contas/01-secret-db.yaml
kubectl apply -f k8s/semana1/contas/02-configmap-init-sql.yaml
kubectl apply -f k8s/semana1/contas/03-configmap-app.yaml
kubectl apply -f k8s/semana1/contas/04-postgres-statefulset.yaml
kubectl apply -f k8s/semana1/contas/05-api-contas-deployment.yaml
kubectl apply -f k8s/semana1/contas/06-api-contas-service.yaml

# Aguardar Postgres ficar Ready antes de subir as APIs
kubectl rollout status statefulset/postgres -n tipsbank-contas --timeout=120s

# Namespace transacoes: Secret, ConfigMap, api-transacoes (com sidecar)
kubectl apply -f k8s/semana1/transacoes/01-secret-db.yaml
kubectl apply -f k8s/semana1/transacoes/02-configmap-app.yaml
kubectl apply -f k8s/semana1/transacoes/03-api-transacoes-deployment.yaml
kubectl apply -f k8s/semana1/transacoes/04-api-transacoes-service.yaml

# Namespace auditoria: deployment com emptyDir (temporário)
kubectl apply -f k8s/semana1/auditoria/01-auditoria-deployment.yaml
kubectl apply -f k8s/semana1/auditoria/02-auditoria-service.yaml

# Namespace web: ConfigMap do nginx (com FQDNs inter-namespace), deployment, service
kubectl apply -f k8s/semana1/web/01-configmap-nginx.yaml
kubectl apply -f k8s/semana1/web/02-web-deployment.yaml
kubectl apply -f k8s/semana1/web/03-web-service.yaml

# Aguardar todos subirem
kubectl rollout status deployment/api-contas     -n tipsbank-contas    --timeout=120s
kubectl rollout status deployment/api-transacoes -n tipsbank-transacoes --timeout=120s
kubectl rollout status deployment/auditoria      -n tipsbank-auditoria  --timeout=120s
kubectl rollout status deployment/web            -n tipsbank-web        --timeout=120s

# ✅ critério: todos os pods Running (2/2 para deployments, 1/1 para STS)
kubectl get pods -A | grep tipsbank

# ✅ critério: services criados
kubectl get svc -A | grep tipsbank

# --- Testar via port-forward ---

# Teste da api-transacoes (transferência)
kubectl port-forward -n tipsbank-transacoes svc/api-transacoes 8082:8080 &
sleep 2
curl -s -X POST http://localhost:8082/transferencias \
  -H 'content-type: application/json' \
  -d '{"origem_id":"11111111-1111-1111-1111-111111111111","destino_id":"22222222-2222-2222-2222-222222222222","valor":"50.00"}' | jq
kill %1  # encerrar o port-forward

# ✅ critério: SPA abre no browser
kubectl port-forward -n tipsbank-web svc/web 8080:8080 &
echo "Abrir http://localhost:8080 no browser — login com CPF 12345678901 / senha giropops"
# (parar manualmente após mostrar no browser)
kill %1
```

---

## Etapa 1.5 — Pod multicontainer + ConfigMap/Secret

```bash
# ✅ critério: pod com 2 containers (2/2)
kubectl get pods -n tipsbank-transacoes

POD_TX=$(kubectl get pod -n tipsbank-transacoes -l app=api-transacoes -o jsonpath='{.items[0].metadata.name}')
echo "Pod: ${POD_TX}"

# ✅ critério: describe mostra 2 containers
kubectl describe pod ${POD_TX} -n tipsbank-transacoes | grep -A 20 "Containers:"

# ✅ critério: log-forwarder exibe logs estruturados da app
kubectl logs -n tipsbank-transacoes -c log-forwarder ${POD_TX}

# ✅ critério: nenhuma variável sensível no YAML — tudo via secretKeyRef/configMapKeyRef
kubectl get deployment api-transacoes -n tipsbank-transacoes -o yaml | grep -A 3 "valueFrom:"

# Mostrar os Secrets (base64, não o valor em claro)
kubectl get secret secret-db -n tipsbank-contas
kubectl get secret secret-db -n tipsbank-transacoes

# Mostrar os ConfigMaps
kubectl get configmap -A | grep tipsbank
kubectl describe configmap configmap-app -n tipsbank-transacoes
```

---

## Etapa 1.6 — PV NFS (RWX) para a auditoria

### No worker1 (${W1_IP}) — preparar o servidor NFS

```bash
# SSH para o worker1
ssh ${W1_IP}

# Instalar e configurar nfs-kernel-server
sudo apt-get install -y nfs-kernel-server
sudo mkdir -p /srv/nfs/auditoria
sudo chown -R 65532:65532 /srv/nfs/auditoria
sudo chmod 755 /srv/nfs/auditoria

# Exportar o diretório
echo "/srv/nfs/auditoria *(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
sudo exportfs -rav
sudo systemctl enable nfs-kernel-server
sudo systemctl restart nfs-kernel-server

# Verificar exportação
showmount -e localhost
exit  # voltar para a máquina local
```

### De volta à máquina local — aplicar manifests NFS

```bash
cd tipsbank

# Substituir IP do NFS server no PV
sed -i "s|NFS_SERVER_IP|${NFS_SERVER_IP}|g" k8s/semana1/auditoria/03-nfs-pv.yaml

# Criar PV e PVC
kubectl apply -f k8s/semana1/auditoria/03-nfs-pv.yaml
kubectl apply -f k8s/semana1/auditoria/04-nfs-pvc.yaml

# ✅ critério: PV Bound ao PVC
kubectl get pv,pvc -A | grep nfs

# Trocar o deployment da auditoria pela versão com PVC (3 réplicas)
kubectl apply -f k8s/semana1/auditoria/05-auditoria-deployment-nfs.yaml
kubectl rollout status deployment/auditoria -n tipsbank-auditoria --timeout=120s

# Verificar 3 réplicas rodando
kubectl get pods -n tipsbank-auditoria -o wide

# --- Disparar 10 transferências para gerar eventos ---
kubectl port-forward -n tipsbank-transacoes svc/api-transacoes 8082:8080 &
sleep 2
for i in $(seq 1 10); do
  curl -s -X POST http://localhost:8082/transferencias \
    -H 'content-type: application/json' \
    -d '{"origem_id":"11111111-1111-1111-1111-111111111111","destino_id":"22222222-2222-2222-2222-222222222222","valor":"1.00"}' | jq .id
done
kill %1

# ✅ critério: pods 1, 2 e 3 veem os mesmos arquivos
PODS=($(kubectl get pod -n tipsbank-auditoria -l app=auditoria -o jsonpath='{.items[*].metadata.name}'))
for p in "${PODS[@]}"; do
  echo "=== ${p} ==="
  kubectl exec -n tipsbank-auditoria ${p} -- ls /data
done

# ✅ critério: mesmas linhas nos 3 pods
for p in "${PODS[@]}"; do
  echo "=== ${p}: $(kubectl exec -n tipsbank-auditoria ${p} -- sh -c 'wc -l /data/*.jsonl 2>/dev/null') ==="
done
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
