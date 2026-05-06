# Semana 2 — Guia de Instalação

Aplique nesta ordem exata. Execute os testes de cada etapa antes de avançar.

---

## Pré-requisito 1 — Provisionar o cluster kubeadm com Vagrant

```bash
# A partir do diretório do Vagrantfile
cd desafios/tipsbank/vagrant

# Subir as 3 VMs e provisionar o cluster (leva ~10 min)
vagrant up

# Verificar que as VMs estão rodando
vagrant status
# Expected: controlplane, worker1, worker2 → running
```

---

## Pré-requisito 2 — Configurar kubectl na máquina local

```bash
# Copiar o kubeconfig do controlplane para a máquina local
cd desafios/tipsbank/vagrant
vagrant ssh controlplane -- sudo cat /etc/kubernetes/admin.conf > ~/.kube/config-tipsbank

# Verificar que o servidor aponta para o IP da rede privada (192.168.56.10)
grep server ~/.kube/config-tipsbank
# Deve mostrar: server: https://192.168.56.10:6443

# Se mostrar 127.0.0.1 ou localhost, corrigir:
sed -i 's|https://127.0.0.1|https://192.168.56.10|' ~/.kube/config-tipsbank
sed -i 's|https://localhost|https://192.168.56.10|' ~/.kube/config-tipsbank

# Mesclar com o kubeconfig principal (mantém outros clusters configurados)
KUBECONFIG=~/.kube/config:~/.kube/config-tipsbank \
  kubectl config view --flatten > /tmp/merged-config && \
  mv /tmp/merged-config ~/.kube/config

# Renomear o context para facilitar identificação
kubectl config rename-context kubernetes-admin@kubernetes kubeadm-tipsbank

# Usar o context do cluster local
kubectl config use-context kubeadm-tipsbank

# Verificar conectividade
kubectl get nodes -o wide
# Expected: controlplane (192.168.56.10), worker1 (192.168.56.11), worker2 (192.168.56.12) — Ready
```

---

## Pré-requisito 3 — Aplicar manifests da semana 1

```bash
# A partir da raiz do projeto tipsbank
cd desafios/tipsbank

kubectl apply -f k8s/semana1/

# Aguardar todos os pods ficarem prontos (~2 min)
kubectl get pods -A | grep tipsbank
# Todos os pods devem estar Running/Ready antes de prosseguir
```

---

## Etapa 2.1 — Ingress Nginx

### 1. Instalar o controller

```bash
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.hostPort.enabled=true \
  --wait
```

### 2. Obter o NodePort e configurar /etc/hosts

```bash
# Obter a porta HTTP do controller
INGRESS_HTTP_PORT=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
echo "NodePort HTTP: $INGRESS_HTTP_PORT"

# Adicionar ao /etc/hosts (usar IP do controlplane: 192.168.56.10)
echo "192.168.56.10  app.tipsbank.local api.tipsbank.local" | sudo tee -a /etc/hosts
```

### 3. Aplicar os Ingresses

```bash
kubectl apply -f k8s/semana2/10-ingress-app.yaml
kubectl apply -f k8s/semana2/11-ingress-contas.yaml
kubectl apply -f k8s/semana2/12-ingress-transacoes.yaml
kubectl apply -f k8s/semana2/13-ingress-auditoria.yaml
```

### 4. Testar (redireciona para HTTPS)

```bash
# Aguardar Ingresses obterem endereço
kubectl get ingress -A

# Obter NodePorts (HTTP e HTTPS)
INGRESS_HTTP_PORT=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
INGRESS_HTTPS_PORT=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
echo "HTTP NodePort: $INGRESS_HTTP_PORT  |  HTTPS NodePort: $INGRESS_HTTPS_PORT"

# SPA — retorna 308 redirect para HTTPS (TLS já configurado nos Ingresses)
curl -o /dev/null -w "%{http_code}" -H 'Host: app.tipsbank.local' http://192.168.56.11:$INGRESS_HTTP_PORT/

# HTTPS direto (ingress-nginx rodando em worker1: 192.168.56.11)
curl -sk https://api.tipsbank.local:$INGRESS_HTTPS_PORT/contas/health/live
curl -sk https://api.tipsbank.local:$INGRESS_HTTPS_PORT/transacoes/health/live
curl -sk https://api.tipsbank.local:$INGRESS_HTTPS_PORT/auditoria/health/live
```

---

## Etapa 2.2 — TLS com cert-manager + Recursos Avançados

### 1. Instalar cert-manager

```bash
helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait
```

### 2. Criar a CA e os issuers

```bash
kubectl apply -f k8s/semana2/14-cert-manager-issuer.yaml

# Aguardar CA ficar pronta (pode levar 30s)
kubectl get certificate -n cert-manager
# STATUS deve ser True/Ready
```

### 3. Aplicar o Secret de Basic Auth

```bash
kubectl apply -f k8s/semana2/15-basic-auth-secret.yaml
```

### 4. Atualizar os Ingresses com TLS (reaplicar os mesmos arquivos)

Os arquivos 10–13 já contêm as anotações TLS e recursos avançados.
Reaplicá-los após o cert-manager estar pronto ativa o TLS automaticamente:

```bash
kubectl apply -f k8s/semana2/10-ingress-app.yaml
kubectl apply -f k8s/semana2/11-ingress-contas.yaml
kubectl apply -f k8s/semana2/12-ingress-transacoes.yaml
kubectl apply -f k8s/semana2/13-ingress-auditoria.yaml

# Aguardar emissão dos certificados
kubectl get certificate -A
kubectl get secret tipsbank-app-tls -n tipsbank-web
kubectl get secret tipsbank-api-tls -n tipsbank-contas
```

### 5. Confiar na CA no laptop (opcional, evita -k no curl)

```bash
kubectl get secret tipsbank-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/tipsbank-ca.crt
# Linux:
sudo cp /tmp/tipsbank-ca.crt /usr/local/share/ca-certificates/tipsbank-ca.crt
sudo update-ca-certificates
```

### 6. Testes — TLS, Basic Auth, Rate Limit, Affinity

```bash
# Extrair a CA e confiar nela (necessário para hey, que não tem flag -k)
kubectl get secret tipsbank-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/tipsbank-ca.crt
# Linux (requer sudo):
sudo cp /tmp/tipsbank-ca.crt /usr/local/share/ca-certificates/tipsbank-ca.crt
sudo update-ca-certificates
# Alternativa sem sudo (apenas para a sessão corrente):
export SSL_CERT_FILE=/tmp/tipsbank-ca.crt

# HTTPS — SPA (usar NodePort 30222; porta 443 não está ativa no kubeadm local)
curl -k https://app.tipsbank.local:30222/
# Deve retornar HTML

# HTTPS — Basic Auth (sem credencial → 401)
curl -k https://api.tipsbank.local:30222/contas/health/live
# Deve retornar 401 Unauthorized

# HTTPS — Basic Auth (com credencial → 200)
curl -k -u admin:giropops https://api.tipsbank.local:30222/contas/health/live
# Deve retornar {"status":"ok"}

# Rate Limit — manter carga por 5s com 50 workers → burst esgota e 429s aparecem
# Observação: limit-req-status-code=429 configurado no ConfigMap ingress-nginx-controller
SSL_CERT_FILE=/tmp/tipsbank-ca.crt hey -z 5s -c 50 https://app.tipsbank.local:30222/ 2>/dev/null | grep -E "Status|\["
# Deve mostrar [200] para os primeiros ~500 e [429] para o restante

# Session Affinity — mesmas sessões devem cair no mesmo pod
for i in $(seq 1 5); do
  curl -sk -c /tmp/tipsbank-cookie.txt -b /tmp/tipsbank-cookie.txt \
    -u admin:giropops \
    https://api.tipsbank.local:30222/transacoes/health/live -D - -o /dev/null 2>/dev/null \
    | grep -i "x-app-version" | tr -d '\r'
done
# Todos devem mostrar a mesma versão (mesmo pod)
```

---

## Etapa 2.4 — Canary Deployment (api-transacoes v2)

### 1. Construir a imagem v2

O código da v2 é **idêntico à v1** — a diferença é apenas `APP_VERSION=v2.0.0`
(o middleware em `main.py` já injeta `X-App-Version` em todas as respostas).

```bash
# Build — mesmo Dockerfile, nova tag
docker build -t zenardi/tipsbank-api-transacoes:v2.0.0 apps/api-transacoes

# Scan de segurança (deve passar: 0 HIGH, 0 CRITICAL)
trivy image --severity HIGH,CRITICAL zenardi/tipsbank-api-transacoes:v2.0.0

# Assinar com Cosign
cosign sign zenardi/tipsbank-api-transacoes:v2.0.0

# Push
docker push zenardi/tipsbank-api-transacoes:v2.0.0
```

### 2. Aplicar v2 e o Ingress canário

```bash
kubectl apply -f k8s/semana2/16-api-transacoes-v2.yaml
kubectl apply -f k8s/semana2/17-ingress-canary.yaml

# Aguardar v2 ficar pronto
kubectl rollout status deployment/api-transacoes-v2 -n tipsbank-transacoes
```

### 3. Verificar proporção 90/10

```bash
# Nota: %header{} não está disponível em curl < 7.84; usar -D para capturar headers
for i in $(seq 1 100); do
  curl -sk https://api.tipsbank.local:30222/transacoes/health/live \
    -D - -o /dev/null 2>/dev/null \
    | grep -i "x-app-version" | tr -d '\r'
done | sort | uniq -c
# Esperado: ~90 "x-app-version: v1.2.0" e ~10 "x-app-version: v2.0.0"

# Forçar rota para v2 (header canário, ignora o peso):
curl -sk -H "X-Canary: always" \
  https://api.tipsbank.local:30222/transacoes/health/live \
  -D - -o /dev/null | grep -i "x-app-version" | tr -d '\r'
# Deve mostrar: x-app-version: v2.0.0
```

---

## Etapa 2.5 — NetworkPolicies Zero-Trust

**Importante**: aplique APÓS validar que todo o tráfego funciona sem as políticas.

```bash
kubectl apply -f k8s/semana2/18-netpol-web.yaml
kubectl apply -f k8s/semana2/19-netpol-contas.yaml
kubectl apply -f k8s/semana2/20-netpol-transacoes.yaml
kubectl apply -f k8s/semana2/21-netpol-auditoria.yaml

# Verificar políticas aplicadas
kubectl get netpol -A | grep tipsbank
```

### Testes de validação

```bash
# BLOQUEIO: auditoria NÃO deve alcançar api-contas
# Containers são distroless (sem shell/wget) — usar python3
kubectl exec -n tipsbank-auditoria \
  $(kubectl get pod -n tipsbank-auditoria -l app=auditoria -o name | head -1) -- \
  python3 -c 'import socket
try:
    socket.create_connection(("api-contas.tipsbank-contas.svc.cluster.local", 8080), timeout=5)
    print("CONECTADO - bloqueio falhou")
except Exception as e:
    print("BLOQUEADO:", e)'
# Deve imprimir: BLOQUEADO: timed out

# PERMITIDO: api-transacoes DEVE alcançar api-contas
kubectl exec -n tipsbank-transacoes \
  $(kubectl get pod -n tipsbank-transacoes -l app=api-transacoes -o name | head -1) \
  -c api-transacoes -- \
  python3 -c 'import urllib.request
r = urllib.request.urlopen("http://api-contas.tipsbank-contas.svc.cluster.local:8080/health/live", timeout=5)
print(r.read().decode())'
# Deve retornar {"status":"ok"}

# PERMITIDO: tráfego externo via Ingress ainda funciona
curl -sk -u admin:giropops https://api.tipsbank.local:30222/contas/health/live
# Deve retornar {"status":"ok"}
```

---

## Etapa 2.3 — Cluster EKS

```bash
# 1. Criar cluster (leva ~15 min, gera custo AWS)
eksctl create cluster -f ../../eksctl/cluster-config-network-policy.yaml

# 2. Renomear context
kubectl config rename-context $(kubectl config current-context) eks-tipsbank
kubectl config get-contexts

# 3. Aplicar semana1 no EKS (EXCETO 09-nfs.yaml)
for f in k8s/semana1/0{0..8}-*.yaml; do
  kubectl --context eks-tipsbank apply -f "$f"
done

# 4. Substituir auditoria por versão EKS (emptyDir)
kubectl --context eks-tipsbank apply -f k8s/semana2/eks/09-auditoria-eks.yaml

# 5. Instalar ingress-nginx no EKS (cria NLB automaticamente)
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --kube-context eks-tipsbank \
  --wait

# 6. Obter hostname do NLB
kubectl --context eks-tipsbank get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 7. Instalar cert-manager no EKS
helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --kube-context eks-tipsbank \
  --wait

# 8. Aplicar semana2 no EKS
kubectl --context eks-tipsbank apply -f k8s/semana2/14-cert-manager-issuer.yaml
kubectl --context eks-tipsbank apply -f k8s/semana2/15-basic-auth-secret.yaml
kubectl --context eks-tipsbank apply -f k8s/semana2/10-ingress-app.yaml
kubectl --context eks-tipsbank apply -f k8s/semana2/11-ingress-contas.yaml
kubectl --context eks-tipsbank apply -f k8s/semana2/12-ingress-transacoes.yaml
kubectl --context eks-tipsbank apply -f k8s/semana2/13-ingress-auditoria.yaml
kubectl --context eks-tipsbank apply -f k8s/semana2/16-api-transacoes-v2.yaml
kubectl --context eks-tipsbank apply -f k8s/semana2/17-ingress-canary.yaml

# NetworkPolicies — Nota: vpc-cni com enableNetworkPolicy: true está ativo
kubectl --context eks-tipsbank apply -f k8s/semana2/18-netpol-web.yaml
kubectl --context eks-tipsbank apply -f k8s/semana2/19-netpol-contas.yaml
kubectl --context eks-tipsbank apply -f k8s/semana2/20-netpol-transacoes.yaml
kubectl --context eks-tipsbank apply -f k8s/semana2/21-netpol-auditoria.yaml

# 9. Verificar pods
kubectl --context eks-tipsbank get pods -A | grep tipsbank

# 10. Destruir cluster ao finalizar (evitar custos)
eksctl delete cluster -f ../../eksctl/cluster-config-network-policy.yaml
```
