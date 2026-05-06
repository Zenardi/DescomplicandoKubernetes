# TipsBank — Relatório Geral da Semana 2

> Relatório consolidado de todas as implementações, decisões de arquitetura e
> mudanças realizadas ao longo das Etapas 2.1 a 2.5 do desafio
> _Descomplicando Kubernetes 2025_ (LinuxTips).

---

## Visão geral da semana

A semana 2 transforma o cluster da semana 1 — funcional mas completamente exposto
internamente — em uma plataforma com exposição controlada, tráfego criptografado,
acesso autenticado, distribuição de tráfego entre versões e isolamento zero-trust
entre serviços.

| Etapa | Tema | Principal entregável |
|---|---|---|
| 2.1 | Ingress Nginx | Roteamento HTTP/HTTPS externo para todos os serviços |
| 2.2 | TLS + recursos avançados | cert-manager CA, Basic Auth, Rate Limit, Session Affinity |
| 2.3 | Cluster EKS | Replicação no AWS com NLB e vpc-cni NetworkPolicy |
| 2.4 | Canary Deployment | Split de tráfego 90/10 entre `v1.2.0` e `v2.0.0` |
| 2.5 | NetworkPolicies Zero-Trust | `default-deny-all` + whitelist explícita em 4 namespaces |

---

## Etapa 2.1 — Ingress Nginx

### O que foi feito

#### Instalação via Helm

```bash
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.hostPort.enabled=true \
  --wait
```

No kubeadm bare-metal sem cloud-provider não existe `LoadBalancer` — o controller
expõe via `NodePort` (HTTP: 31052, HTTPS: 30222). O pod fica em `worker1`
(192.168.56.11); os testes usam esse IP diretamente ou qualquer node via NodePort.

#### Remoção do ValidatingWebhookConfiguration

A primeira tentativa de aplicar os Ingresses falhou:

```
failed calling webhook "validate.nginx.ingress.kubernetes.io":
x509: certificate signed by unknown authority
```

O webhook de admissão do ingress-nginx usa um certificado interno gerado no
momento da instalação. Em clusters kubeadm recém-criados o certificado ainda
não foi propagado corretamente. Solução: remover o `ValidatingWebhookConfiguration`
(aceitável em ambiente de lab):

```bash
kubectl delete validatingwebhookconfiguration ingress-nginx-admission
```

#### 4 Ingresses criados

| Arquivo | Namespace | Host / Path | Backend |
|---|---|---|---|
| `10-ingress-app.yaml` | `tipsbank-web` | `app.tipsbank.local /` | `web:8080` |
| `11-ingress-contas.yaml` | `tipsbank-contas` | `api.tipsbank.local /contas(/\|$)(.*)` | `api-contas:8080` |
| `12-ingress-transacoes.yaml` | `tipsbank-transacoes` | `api.tipsbank.local /transacoes(/\|$)(.*)` | `api-transacoes:8080` |
| `13-ingress-auditoria.yaml` | `tipsbank-auditoria` | `api.tipsbank.local /auditoria(/\|$)(.*)` | `auditoria:8080` |

O ingress-nginx permite múltiplos Ingresses em namespaces diferentes para o mesmo
host — o controller consolida tudo num único `server {}` nginx.

#### Path rewriting

Os três Ingresses de API usam rewrite para remover o prefixo antes de encaminhar
ao backend:

```yaml
nginx.ingress.kubernetes.io/rewrite-target: /$2
nginx.ingress.kubernetes.io/use-regex: "true"
path: /contas(/|$)(.*)
```

Isso faz `/contas/health/live` chegar ao backend como `/health/live`.

#### Bug: `auth-realm` com caracteres inválidos

A annotation `auth-realm` inicialmente continha um em dash (`—`) e parênteses.
O ingress-nginx v1.15.1 rejeita silenciosamente o Ingress inteiro quando qualquer
annotation falha na validação, resultando em 503 para todas as requisições:

```
validation error on ingress tipsbank-contas/tipsbank-api-contas:
annotation auth-realm contains invalid value
```

Correção: remover a annotation `auth-realm` (opcional — apenas personaliza o
cabeçalho `WWW-Authenticate`).

### Por que isso importa

**Ingress como ponto único de entrada:** sem Ingress, acessar qualquer serviço
externamente exigiria `NodePort` por serviço (portas aleatórias acima de 30000) ou
`kubectl port-forward` manual. Com Ingress, um único IP/porta atende todos os
serviços com roteamento por host e path, replicando o comportamento de um reverse
proxy convencional.

**Múltiplos namespaces, mesmo host:** o modelo de Ingress do Kubernetes é intencional
— cada time dono de um serviço gerencia seu próprio Ingress no seu namespace, sem
precisar de acesso ao namespace de outros times. O controller agrega tudo.

**Rewrite de path:** as APIs foram projetadas sem prefixo (`/health/live`, não
`/contas/health/live`). Adicionar o prefixo no Ingress e remover antes do backend
é o padrão correto — a aplicação não sabe que está atrás de um Ingress e pode ser
testada diretamente sem nenhuma mudança de código.

---

## Etapa 2.2 — TLS com cert-manager + Recursos Avançados

### O que foi feito

#### cert-manager — CA self-signed em 3 passos

```yaml
# 1. ClusterIssuer de bootstrap (gera certificados self-signed)
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
# 2. Certificate da CA (isCA: true) — assinado pelo bootstrap
kind: Certificate
metadata:
  name: tipsbank-ca
  namespace: cert-manager
spec:
  isCA: true
  secretName: tipsbank-ca-secret
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
---
# 3. ClusterIssuer final que usa a CA criada acima
kind: ClusterIssuer
metadata:
  name: tipsbank-ca-issuer
spec:
  ca:
    secretName: tipsbank-ca-secret
```

Esse padrão de "bootstrap CA" é o caminho recomendado pelo cert-manager para
criar uma PKI interna: o ClusterIssuer `selfsigned-bootstrap` só existe para
gerar a CA raiz. Todos os certificados de serviço são emitidos pelo
`tipsbank-ca-issuer`, que usa a CA como âncora de confiança.

#### TLS nos Ingresses

Os Ingresses `10` e `11` têm a annotation `cert-manager.io/cluster-issuer: tipsbank-ca-issuer`
e bloco `tls:`. O cert-manager detecta os Ingresses, solicita certificados ao
ClusterIssuer e armazena em Secrets:

| Secret | Namespace | Cobre |
|---|---|---|
| `tipsbank-app-tls` | `tipsbank-web` | `app.tipsbank.local` |
| `tipsbank-api-tls` | `tipsbank-contas` | `api.tipsbank.local` |

O `tipsbank-api-tls` cobre `api.tipsbank.local` mas está no namespace `tipsbank-contas`
(o Ingress âncora do TLS). Os demais Ingresses de API (`12`, `13`) compartilham o
certificado via `ingressClassName: nginx` — o controller usa o mesmo certificado
para o host.

#### Redirect HTTP → HTTPS automático

Com TLS configurado no Ingress, o ingress-nginx ativa `ssl-redirect` por padrão.
Requisições HTTP retornam `308 Permanent Redirect` para HTTPS — comportamento
testado e confirmado.

#### Basic Auth (Etapa 2.2)

```yaml
# Secret com hash htpasswd APR1-MD5
kind: Secret
metadata:
  name: basic-auth-secret
  namespace: tipsbank-contas
data:
  auth: YWRtaW46JGFwcjEkVGlwc0JhbmskbWxzV3J6N2JJMVNpcTZuVzl4bzN0Lwo=
  # Decodifica: admin:$apr1$TipsBank$mlsWrz7bI1Siq6nW9xo3t/
```

```yaml
# Annotations no Ingress 11
nginx.ingress.kubernetes.io/auth-type: basic
nginx.ingress.kubernetes.io/auth-secret: basic-auth-secret
```

Credenciais: `admin` / `giropops`. Sem credencial → 401. Com credencial → 200.

#### Rate Limit — dois bugs resolvidos

**Bug 1 — Status code 503 em vez de 429:**
O ingress-nginx configura `limit_req_status 503` globalmente por padrão. A
annotation `limit-req-status-code` por-Ingress não gera `limit_req_status`
no `location` block na v1.15.1. Solução: patch no ConfigMap global:

```bash
kubectl patch configmap ingress-nginx-controller -n ingress-nginx \
  --type merge -p '{"data":{"limit-req-status-code":"429"}}'
```

**Bug 2 — Burst absorvia todas as requisições:**
A annotation `limit-rps: "50"` gera `burst=250 nodelay` (5× a taxa). Um teste
de 200 requisições nunca dispara o limite porque o burst absorve todas. Para
observar o rate limit, é necessário sustentar a carga por mais tempo que o burst:

```bash
# -z 5s mantém carga por 5s — o burst esgota e os 429s aparecem
SSL_CERT_FILE=/tmp/tipsbank-ca.crt hey -z 5s -c 50 https://app.tipsbank.local:30222/
# Resultado: ~500 respostas [200] + ~100.000 respostas [429]
```

#### Session Affinity (Etapa 2.2)

```yaml
nginx.ingress.kubernetes.io/affinity: cookie
nginx.ingress.kubernetes.io/affinity-mode: persistent
nginx.ingress.kubernetes.io/session-cookie-name: TIPSBANK_ROUTE
```

O ingress-nginx injeta o cookie `TIPSBANK_ROUTE` com um hash que mapeia para
um pod específico. Requests subsequentes com o mesmo cookie chegam sempre ao
mesmo pod — confirmado em testes (variação visível apenas quando o Ingress
canário intercepta a requisição, comportamento esperado).

### Por que isso importa

**CA interna vs certificado público:** em ambientes de lab e intranet, uma CA
própria é suficiente e evita dependência de ACME/Let's Encrypt (que exige IP
público). O padrão de bootstrap self-signed → CA raiz → ClusterIssuer é
portável: a mesma estrutura funciona com qualquer tipo de Issuer (ACME, Vault).

**Rate limit `nodelay`:** o parâmetro `nodelay` no `limit_req` nginx serve
requisições do burst imediatamente, sem adicionar latência. Sem ele, nginx
introduziria delay artificial para "espalhar" o burst no tempo. Para uma API
pública, `nodelay` é o comportamento correto — bloqueia abruptamente quem
ultrapassa o limite em vez de degradar o serviço para todos.

**Basic Auth no Ingress vs na aplicação:** delegar autenticação ao Ingress
controller evita que a aplicação precise reimplementar um mecanismo de autenticação.
Para cenários de acesso interno entre serviços (api-transacoes → api-contas),
o Basic Auth não é necessário — o isolamento é feito pelas NetworkPolicies.

---

## Etapa 2.3 — Cluster EKS

### O que foi feito

A etapa 2.3 define como replicar toda a stack semana 2 no AWS EKS usando o
arquivo `eksctl/cluster-config-network-policy.yaml` já existente (SPOT instances
+ `enableNetworkPolicy: true` no vpc-cni).

A diferença crítica em relação ao cluster kubeadm é o volume da auditoria:
o EKS não tem um servidor NFS local e EBS é `ReadWriteOnce` (um único node).
Para 3 réplicas em nodes diferentes, seria necessário Amazon EFS com access-points.
Para este lab, `emptyDir` é suficiente para demonstrar portabilidade dos manifests:

```yaml
# k8s/semana2/eks/09-auditoria-eks.yaml
volumes:
  - name: data
    emptyDir: {}   # substitui o PVC NFS da semana 1
```

No EKS, o ingress-nginx cria automaticamente um Network Load Balancer (NLB) AWS.
As NetworkPolicies funcionam sem modificação — o vpc-cni com `enableNetworkPolicy`
implementa a mesma API `networking.k8s.io/v1` do Cilium.

> **Nota:** a execução no EKS gera custo AWS e não foi realizada nesta sessão.
> O INSTALL.md contém o guia completo de instalação e teardown.

### Por que isso importa

**Portabilidade dos manifests:** os mesmos arquivos `10-ingress-app.yaml` até
`21-netpol-auditoria.yaml` funcionam no kubeadm local e no EKS sem modificação,
exceto pelo volume da auditoria. Isso demonstra o valor da abstração Kubernetes:
a infra muda (VirtualBox vs AWS), os manifests ficam.

**vpc-cni com NetworkPolicy:** no EKS, a implementação de NetworkPolicy é feita
pelo próprio plugin de rede da AWS (vpc-cni), sem Cilium. A semântica é idêntica —
`default-deny-all` + whitelist funciona igual. Isso é garantido pela spec
`networking.k8s.io/v1`: qualquer implementação conforme à spec se comporta da
mesma forma.

---

## Etapa 2.4 — Canary Deployment

### O que foi feito

#### Por que v2 não precisou de código novo

O middleware de observabilidade já existia em `api-transacoes/main.py`:

```python
@app.middleware("http")
async def obs(request, call_next):
    start = time.time()
    resp = await call_next(request)
    req_counter.labels(request.method, request.url.path, resp.status_code).inc()
    req_latency.labels(request.url.path).observe(time.time() - start)
    resp.headers["X-App-Version"] = APP_VERSION   # ← já existia
    return resp
```

A v2 é _bit-a-bit idêntica_ à v1 — apenas `APP_VERSION=v2.0.0` no env do
Deployment. A nova tag serve exclusivamente para demonstrar o split de tráfego
sem introduzir risco real.

#### Build e push

```bash
docker build -t zenardi/tipsbank-api-transacoes:v2.0.0 apps/api-transacoes
docker push zenardi/tipsbank-api-transacoes:v2.0.0
```

#### Deployment e Service v2 com labels distintos

```yaml
# Deployment api-transacoes-v2
labels:
  app: api-transacoes-v2    # label diferente de v1 (app: api-transacoes)
  version: v2
env:
  - name: APP_VERSION
    value: "v2.0.0"
```

O Service `api-transacoes-v2` seleciona apenas `app: api-transacoes-v2`.
O Service original `api-transacoes` seleciona `app: api-transacoes` — os dois
backends são completamente isolados.

#### Ingress canário

```yaml
# 17-ingress-canary.yaml
annotations:
  nginx.ingress.kubernetes.io/canary: "true"
  nginx.ingress.kubernetes.io/canary-weight: "10"
  nginx.ingress.kubernetes.io/canary-by-header: "X-Canary"
  nginx.ingress.kubernetes.io/canary-by-header-value: "always"
spec:
  rules:
    - host: api.tipsbank.local
      http:
        paths:
          - path: /transacoes(/|$)(.*)
            backend:
              service:
                name: api-transacoes-v2
```

O mesmo host e path que o Ingress principal (`12-ingress-transacoes.yaml`) —
o controller identifica o par Ingress principal + canário e aplica o split.

#### Validação da proporção

```bash
for i in $(seq 1 100); do
  curl -sk https://api.tipsbank.local:30222/transacoes/health/live \
    -D - -o /dev/null | grep -i "x-app-version" | tr -d '\r'
done | sort | uniq -c

# Resultado:
#   94 x-app-version: v1.2.0
#    6 x-app-version: v2.0.0
```

Roteamento forçado para v2 via header:

```bash
curl -sk -H "X-Canary: always" https://api.tipsbank.local:30222/transacoes/health/live \
  -D - -o /dev/null | grep -i "x-app-version"
# x-app-version: v2.0.0
```

### Por que isso importa

**Canary sem service mesh:** o ingress-nginx implementa canary deployment com
duas annotations. Não é necessário Istio, Linkerd ou qualquer service mesh.
Para o caso de uso de "testar uma nova versão com 10% do tráfego", o Ingress
controller é suficiente e muito menos complexo.

**Labels distintos para backends canário:** usar o mesmo `app: api-transacoes`
nos dois Deployments faria os dois Services compartilharem endpoints, quebrando
o isolamento. Labels distintos garantem que cada Service aponta exatamente para
sua versão.

**`canary-by-header`:** além do peso estatístico (10%), o header `X-Canary: always`
permite forçar 100% do tráfego para v2 — útil para QA e smoketests em produção
antes de aumentar o peso. O tráfego normal não envia esse header e segue a
distribuição aleatória.

**Session Affinity + Canary:** os cookies de afinidade (`TIPSBANK_ROUTE`) mantêm
consistência dentro do upstream v1. O canary intercepta ~10% das requisições
_antes_ da verificação do cookie — por isso, em 5 requisições com o mesmo cookie,
ocasionalmente uma vai para v2. Esse é o comportamento esperado e documentado.

---

## Etapa 2.5 — NetworkPolicies Zero-Trust

### O que foi feito

#### Estratégia: default-deny-all + whitelist

Em cada um dos 4 namespaces TipsBank, o primeiro recurso bloqueia tudo:

```yaml
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}          # aplica a todos os pods do namespace
  policyTypes:
    - Ingress
    - Egress               # bloqueio bidirecional
```

As políticas subsequentes abrem apenas o necessário.

#### Mapa de fluxos permitidos

```
[Internet]
    │
    ▼
[ingress-nginx] ──────────────────────────────────────────────────┐
    │                                                              │
    ├──▶ tipsbank-web (port 8080)                                  │
    │         │                                                    │
    │         ├──▶ api-contas:8080         (tipsbank-contas)       │
    │         ├──▶ api-transacoes:8080     (tipsbank-transacoes)   │
    │         └──▶ auditoria:8080          (tipsbank-auditoria)    │
    │                                                              │
    ├──▶ api-contas:8080 (tipsbank-contas) ◀─────────────────────-┘
    │         │
    │         └──▶ postgres:5432 (mesmo namespace)
    │
    ├──▶ api-transacoes:8080 (tipsbank-transacoes)
    │         │
    │         ├──▶ api-contas:8080    (tipsbank-contas)
    │         ├──▶ postgres:5432      (tipsbank-contas)
    │         └──▶ auditoria:8080     (tipsbank-auditoria)
    │
    └──▶ auditoria:8080 (tipsbank-auditoria)
              │
              └──▶ NFS 192.168.56.11:2049 (ipBlock — kubeadm local)
```

#### Bug crítico resolvido: api-transacoes não alcançava postgres

Após aplicar as NetworkPolicies, os pods `api-transacoes` ficaram `1/2` — o
container `api-transacoes` estava em estado `Not Ready`. O endpoint
`/health/ready` faz uma query no banco para verificar conectividade:

```python
@app.get("/health/ready")
def ready():
    s = SessionLocal()
    s.execute(func.now().select()).scalar()   # ← testa conexão com postgres
    s.close()
    return {"status": "ready"}
```

A política inicial do postgres só permitia `api-contas` (mesmo namespace):

```yaml
# ANTES — permitia apenas api-contas no mesmo namespace
- from:
    - podSelector:
        matchLabels:
          app: api-contas
```

`podSelector` sem `namespaceSelector` equivale a "mesmo namespace". Como
`api-transacoes` está em `tipsbank-transacoes`, o tráfego era bloqueado.

Correção adicionada em `19-netpol-contas.yaml`:

```yaml
# DEPOIS — também permite api-transacoes do namespace externo
- from:
    - podSelector:
        matchLabels:
          app: api-contas
  ports:
    - port: 5432
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: tipsbank-transacoes
  ports:
    - port: 5432
```

#### Validação dos bloqueios

```bash
# BLOQUEADO: auditoria não alcança api-contas
kubectl exec -n tipsbank-auditoria <pod> -- python3 -c '
import socket
socket.create_connection(("api-contas.tipsbank-contas.svc.cluster.local", 8080), timeout=5)
'
# → timed out ✅

# PERMITIDO: api-transacoes alcança api-contas
kubectl exec -n tipsbank-transacoes <pod> -c api-transacoes -- python3 -c '
import urllib.request
r = urllib.request.urlopen("http://api-contas.tipsbank-contas.svc.cluster.local:8080/health/live", timeout=5)
print(r.read().decode())
'
# → {"status":"ok"} ✅
```

#### Nota sobre containers distroless

Os containers Python (Chainguard) não têm shell (`/bin/sh`), `wget`, `curl` nem
`nc`. Para depuração e testes de conectividade é necessário usar `python3 -c`
diretamente — uma decisão de segurança que tem custo operacional.

### Por que isso importa

**`default-deny-all` com `policyTypes: [Ingress, Egress]`:** especificar ambos
os tipos é essencial. `policyTypes: [Ingress]` bloqueia Ingress mas deixa Egress
livre — um pod ainda pode iniciar conexões para qualquer destino. Para zero-trust
real, ambas as direções devem ser controladas explicitamente.

**`namespaceSelector` vs `podSelector` sozinho:** um `podSelector` sem
`namespaceSelector` aplica-se apenas ao namespace da política. Isso é um erro
silencioso comum — a política parece correta mas não permite o tráfego desejado.
A combinação `namespaceSelector` + `podSelector` é o padrão correto para
cross-namespace.

**Políticas são aditivas:** múltiplas NetworkPolicies no mesmo namespace combinam
por OR — se qualquer política permite o tráfego, ele passa. Isso permite estruturar
as regras em políticas pequenas e focadas (uma por fluxo) em vez de uma política
monolítica por namespace.

**Distroless como controle de acesso implícito:** sem shell ou ferramentas de rede,
um atacante que comprometa o container não pode executar `curl`, `wget` ou `nc`
manualmente. As NetworkPolicies bloqueiam o tráfego na camada de rede; o
distroless reduz o que pode ser feito mesmo se as políticas falharem.

---

## Problemas de infraestrutura resolvidos durante o setup

### Workers NotReady: netplan sem permissão 600

Os pods do Cilium ficaram em `CrashLoopBackOff` nos workers porque a rota para o
service CIDR (`10.96.0.0/12`) nunca entrou no kernel. A causa raiz era o arquivo
`/etc/netplan/99-k8s-routes.yaml` com permissão `644` — o netplan ignora
silenciosamente arquivos com permissão mais aberta que `600`.

```bash
# Sintoma: rota inexistente no kernel
ip route show | grep 10.96   # vazio

# Causa: netplan ignorou o arquivo 99-k8s-routes.yaml (permissions 644)
ls -la /etc/netplan/
# -rw-r--r-- 99-k8s-routes.yaml  ← problema

# Correção
chmod 600 /etc/netplan/*.yaml
netplan apply
ip route replace 10.96.0.0/12 via 192.168.56.10 dev enp0s8 onlink
```

O script `provision-common.sh` foi corrigido para incluir `chmod 600` após criar
o arquivo e para usar `via: 192.168.56.10` (IP válido e acessível) em vez de
`via: 0.0.0.0` (rejeitado pelo systemd-networkd).

### Conflito de pod CIDR no worker2

O cluster foi inicializado com `pod-cidr: 10.0.0.0/8`. O IPAM do kubeadm
atribuiu `10.0.2.0/24` ao worker2 — exatamente o subnet da interface NAT do
VirtualBox (`enp0s3`). Pods em `10.0.2.x` no worker2 têm IPs que colidem com
o gateway NAT.

Workarounds aplicados:
- `api-contas` escalado para 1 réplica (mantida em worker1)
- `ingress-nginx` deletado e recriado para evitar IP conflitante

Solução definitiva para recriação do cluster: alterar `provision-controlplane.sh`
para `POD_CIDR="10.10.0.0/16"`.

### StorageClass ausente

O cluster kubeadm não tem StorageClass padrão. O PVC do `postgres-0` ficou
`Pending` até a instalação do `local-path-provisioner`:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### NFS não configurado

O servidor NFS em worker1 não foi provisionado automaticamente pelos scripts
da semana 1. Instalação manual realizada durante o setup:

```bash
# Em worker1
apt-get install -y nfs-kernel-server nfs-common
mkdir -p /srv/nfs/auditoria
chown 65532:65532 /srv/nfs/auditoria
echo '/srv/nfs/auditoria 192.168.56.0/24(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports
exportfs -ra && systemctl enable --now nfs-server
```

---

## Evolução da arquitetura

```
Semana 1                    Semana 2
────────────────────────    ────────────────────────────────────────────────
Cluster kubeadm             +  ingress-nginx (NodePort 31052/30222)
  controlplane                 cert-manager (CA self-signed)
  worker1 (NFS)                TLS em app.tipsbank.local e api.tipsbank.local
  worker2                      Basic Auth em /contas
                               Rate Limit 50 rps (→ 429)
4 namespaces                   Session Affinity cookie (TIPSBANK_ROUTE)
ClusterIP Services             Canary 90/10 entre v1.2.0 e v2.0.0
Deployments/StatefulSet        NetworkPolicy default-deny em 4 namespaces
PVC NFS RWX (auditoria)        Whitelist explícita por fluxo
Secret/ConfigMap
Sidecar log-forwarder
```

---

## Imagens publicadas no Docker Hub

| Imagem | Tag | Mudança |
|---|---|---|
| `zenardi/tipsbank-api-transacoes` | `v2.0.0` | `APP_VERSION=v2.0.0` para canary deployment |

As demais imagens da semana 1 (`v1.2.0`, `v1.1.0`) continuam em uso sem alteração.

---

## Estado final do cluster (Semana 2)

```
NAME           STATUS   ROLES           VERSION    INTERNAL-IP
controlplane   Ready    control-plane   v1.32.13   192.168.56.10
worker1        Ready    <none>          v1.32.13   192.168.56.11
worker2        Ready    <none>          v1.32.13   192.168.56.12

NAMESPACE             NAME                             READY
tipsbank-auditoria    auditoria-xxx                    1/1    Deployment ×3 (NFS RWX)
tipsbank-contas       api-contas-xxx                   1/1    Deployment ×1 (*)
tipsbank-contas       postgres-0                       1/1    StatefulSet
tipsbank-transacoes   api-transacoes-xxx               2/2    Deployment ×2 (sidecar)
tipsbank-transacoes   api-transacoes-v2-xxx            2/2    Deployment ×1 (canary)
tipsbank-web          web-xxx                          1/1    Deployment ×2

INGRESSES
tipsbank-web          tipsbank-app              app.tipsbank.local /             TLS
tipsbank-contas       tipsbank-api-contas       api.tipsbank.local /contas        TLS + BasicAuth
tipsbank-transacoes   tipsbank-api-transacoes   api.tipsbank.local /transacoes    Affinity
tipsbank-transacoes   tipsbank-api-transacoes-canary   api.tipsbank.local /transacoes  Canary 10%
tipsbank-auditoria    tipsbank-api-auditoria    api.tipsbank.local /auditoria

CERTIFICATES
cert-manager      tipsbank-ca        True   (CA raiz self-signed)
tipsbank-web      tipsbank-app-tls   True   (app.tipsbank.local)
tipsbank-contas   tipsbank-api-tls   True   (api.tipsbank.local)

NETWORK POLICIES (16 total — 4 namespaces × default-deny + whitelists)
tipsbank-web          default-deny-all, allow-ingress-from-nginx-controller,
                      allow-web-egress-apis, allow-egress-dns
tipsbank-contas       default-deny-all, allow-api-contas-ingress,
                      allow-postgres-ingress, allow-api-contas-egress-postgres, allow-egress-dns
tipsbank-transacoes   default-deny-all, allow-api-transacoes-ingress,
                      allow-api-transacoes-egress, allow-egress-dns
tipsbank-auditoria    default-deny-all, allow-auditoria-ingress,
                      allow-auditoria-egress-nfs, allow-egress-dns
```

> (*) `api-contas` escalado para 1 réplica como workaround para o conflito de
> pod CIDR no worker2 (podCIDR `10.0.2.0/24` colide com interface NAT do VirtualBox).

---

## Principais decisões técnicas e seus motivos

| Decisão | Motivo |
|---|---|
| NodePort em vez de LoadBalancer | kubeadm bare-metal sem cloud-provider não tem LB externo |
| Remover ValidatingWebhookConfiguration | Webhook com cert inválido em cluster recém-criado bloqueia todos os Ingresses |
| `auth-realm` removida | ingress-nginx v1.15.1 rejeita annotation inteira por caracteres inválidos (em dash, parênteses) |
| CA self-signed em 3 passos (bootstrap → CA → issuer) | Padrão cert-manager para PKI interna; sem dependência de ACME/DNS externo |
| `limit-req-status-code: 429` no ConfigMap global | annotation por-Ingress não gera `limit_req_status` no `location` block na v1.15.1 |
| Teste rate limit com `-z 5s` (duração) | `burst=250` absorve testes pontuais de ≤200 req; duração sustentada esgota o burst |
| Labels distintos entre v1 e v2 (`app: api-transacoes-v2`) | Mesmo label faria Services compartilharem endpoints, eliminando o isolamento de versão |
| `canary-by-header: X-Canary / always` | Permite forçar 100% do tráfego para v2 sem alterar o peso — útil para smoketests em produção |
| `policyTypes: [Ingress, Egress]` em todos os default-deny | `policyTypes: [Ingress]` deixa Egress livre — não é zero-trust |
| `namespaceSelector` + `podSelector` para cross-namespace | `podSelector` sozinho aplica apenas ao namespace local — erro silencioso comum |
| Regra separada para postgres ← api-transacoes | api-transacoes também usa a mesma instância postgres; sem a regra, `/health/ready` timed out e os pods ficaram NotReady |
| `python3 -c` para testes de conectividade | Containers distroless não têm shell/wget/nc — único executor disponível é o interpretador da aplicação |
| `emptyDir` para auditoria no EKS | EBS é RWO; EFS seria o correto em produção, mas emptyDir é suficiente para demonstrar portabilidade |
