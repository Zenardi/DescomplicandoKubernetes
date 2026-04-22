# TipsBank — Manual do Aluno

Esse é o seu guia. Vai te levar de um repositório com uma app Python até um **banco digital rodando em Kubernetes com compliance**. Leia na ordem. Não pule.

## Como usar esse manual

- Cada **semana** tem um objetivo geral
- Cada semana é dividida em **etapas** pequenas e testáveis
- Cada etapa tem **4 blocos fixos**:
  - **Objetivo**: o que você vai entregar
  - **Revise antes**: qual Day do treinamento é a base
  - **Passo a passo**: o que fazer
  - **Critérios de aceite**: como saber que ficou pronto

- Ao fim de cada semana, registre evidências (prints, outputs) no seu repositório em `docs/EVIDENCIAS.md`.

---

# SEMANA 1 — Fundações

> **Objetivo da semana**: subir um cluster kubeadm funcional, conteinerizar a app em imagens Distroless (e nonroot no caso do `web`) assinadas com Cosign, e ter os **4 serviços** (3 APIs + frontend) rodando como workloads básicos com ConfigMap, Secret e Volume.

---

## Etapa 1.1 — Entender a aplicação localmente

**Objetivo**: rodar o TipsBank no docker-compose e conseguir explicar, em uma conversa de 2 minutos, o que cada serviço faz.

**Revise antes**: Day-1 (containers), Day-13 (container image)

**Passo a passo**:
1. Clone o repositório TipsBank
2. Rode `docker compose up --build`
3. Abra `http://localhost:8080` no navegador — é o internet banking completo em SPA (landing, abrir conta, login, dashboard, transferir, extrato, auditoria)
4. Entre com uma das contas seed (senha: `giropops`) ou abra uma conta nova
5. Teste os endpoints HTTP diretamente (listagem no `README.md`)
6. Leia os 3 `main.py` em `apps/` — entenda que `api-transacoes` chama `api-contas` e publica evento em `auditoria`
7. Leia `apps/web/` — SPA servida por `nginx-unprivileged` com proxy reverso para as 3 APIs
8. Leia o `sql/init.sql` (note a coluna `senha_hash` com o hash `bcrypt` pré-computado)

**Sobre autenticação**: `api-contas` expõe `POST /login` que valida CPF + senha (hash `bcrypt`). Toda conta nova exige senha no cadastro (`POST /contas` com campo `senha`). As senhas nunca são armazenadas em claro.

**Critérios de aceite**:
- `curl http://localhost:8081/contas` retorna as 2 contas seed (sem campo `senha_hash` exposto)
- Login bate 200 com senha certa e 401 com errada:
  ```bash
  curl -X POST http://localhost:8081/login -H 'content-type: application/json' \
    -d '{"documento":"12345678901","senha":"giropops"}'
  ```
- Uma transferência de R$ 100 muda o saldo de ambas as contas
- O arquivo `/data/eventos-YYYY-MM-DD.jsonl` dentro do container `auditoria` tem uma linha por transferência
- SPA em `localhost:8080` funciona ponta a ponta (abrir, logar, transferir, ver extrato)

---

## Etapa 1.2 — Build Distroless, scan com Trivy, assinatura Cosign

**Objetivo**: 4 imagens de container (3 APIs Distroless + `web` nonroot nginx-unprivileged) com **zero vulnerabilidades HIGH/CRITICAL** e **assinadas** via Cosign, publicadas num registry que você controla (Docker Hub ou ghcr.io).

**Revise antes**: Day-13 inteiro

**Passo a passo**:
1. Os `Dockerfile`s em `apps/*/Dockerfile` **já estão no padrão multi-stage**: builder `python:3.11-slim-bookworm` (com pip e build tools) + runtime `gcr.io/distroless/python3-debian12:nonroot` (sem shell, sem package manager, user uid 65532). Leia e entenda. Você deve justificar no seu `EVIDENCIAS.md` por que isso reduz vulnerabilidades.
2. Entenda o truque: no builder a gente faz `pip install --target=/packages` em vez de venv. Por quê? Porque no runtime Distroless o binário `python3` vive em path diferente e o venv quebraria. Copiando o `/packages` e setando `PYTHONPATH=/packages` + `PATH=/packages/bin:$PATH`, a app roda limpo.
3. Rode o scan:
   ```bash
   docker build -t seuuser/tipsbank-api-contas:v1.0.0 apps/api-contas
   trivy image --severity HIGH,CRITICAL seuuser/tipsbank-api-contas:v1.0.0
   ```
4. Repita para `api-transacoes`, `auditoria` e `web`
5. Rode também o **Docker Scout** (Day-13) e anexe o relatório no `EVIDENCIAS.md`
6. Gere uma chave Cosign (ou use keyless OIDC) e **assine** cada imagem:
   ```bash
   cosign sign seuuser/tipsbank-api-contas:v1.0.0
   ```
7. Verifique a assinatura com `cosign verify`

O script `scripts/build-e-assinar.sh` é um **guia de referência**. Você pode executar, mas é sua responsabilidade entender cada passo.

> **Nota sobre a imagem Distroless escolhida**: usamos `gcr.io/distroless/python3-debian12` (Google) por ter wheels para todas as libs modernas (pydantic-core, psycopg) e versão Python estável. Se preferir experimentar **Wolfi/Chainguard** (também Distroless), fique à vontade — desde que passe no Trivy limpo. O Day-13 ensina os dois caminhos; escolha o que te deixa mais confortável.

**Critérios de aceite**:
- `trivy image` devolve **0 vulnerabilidades HIGH ou CRITICAL** nas 4 imagens
- `cosign verify` passa nas 4 imagens
- `docker inspect` mostra que o usuário final é não-root (UID 65532 nas 3 APIs, UID 101 no `web`)
- Tamanho final das imagens Python < 150 MB; `web` (nginx) < 30 MB

---

## Etapa 1.3 — Cluster kubeadm multi-node

**Objetivo**: cluster com **1 control-plane + 2 workers** instalado do zero com kubeadm, containerd e CNI funcionando.

**Revise antes**: Day-5 completo

**Passo a passo**:
1. Provisione 3 VMs Linux (Vagrant, Multipass, VMs em cloud — como preferir). Ubuntu 22.04 ou superior.
2. Em todas: instale containerd, kubeadm, kubelet, kubectl (versões compatíveis — veja a docs oficial do K8s)
3. No control-plane: `kubeadm init` com `--pod-network-cidr` compatível com o CNI que escolher (Calico, Flannel, Cilium)
4. Junte os workers com `kubeadm join`
5. Instale o CNI
6. Verifique:
   ```bash
   kubectl get nodes -o wide
   kubectl get pods -A
   ```

**Armadilha comum**: esquecer de configurar as portas TCP/UDP (o Day-1 lista todas). Se os workers não juntam, é quase sempre firewall ou swap.

**Critérios de aceite**:
- 3 nodes `Ready`
- Todos os pods do `kube-system` em `Running`
- Você consegue fazer `kubectl run nginx --image=nginx` e o pod vai para um worker (não para o control-plane, a menos que remova o taint — **não remova**)

---

## Etapa 1.4 — Namespaces, Deployments iniciais e Services

**Objetivo**: subir as 3 APIs + frontend como Deployment e Postgres como StatefulSet em namespaces separados. Sem ingress ainda — acesso via `port-forward`.

**Revise antes**: Day-2 (Pods), Day-3 (Deployments), Day-7 (Services, StatefulSet)

**Passo a passo**:
1. Crie os namespaces: `tipsbank-contas`, `tipsbank-transacoes`, `tipsbank-auditoria`, `tipsbank-web`
2. Escreva `secret-db.yaml` (Secret Opaque) com as credenciais do Postgres no ns `tipsbank-contas`
3. Escreva `configmap-app.yaml` com as URLs dos serviços
4. **StatefulSet do Postgres** no `tipsbank-contas`:
   - 1 réplica inicial
   - Headless Service (Day-7)
   - PVC de 2Gi (StorageClass default — Day-6)
   - Monta o `init.sql` via ConfigMap em `/docker-entrypoint-initdb.d/` (note que o seed já inclui `senha_hash` pré-computado para as 2 contas iniciais)
5. **Deployment** de `api-contas` (2 réplicas) no mesmo ns, com Service ClusterIP
6. **Deployment** de `api-transacoes` (2 réplicas) no ns `tipsbank-transacoes`
7. **Deployment** de `auditoria` (2 réplicas) no ns `tipsbank-auditoria` — use `emptyDir` temporariamente (vai virar NFS na etapa 1.6)
8. **Deployment** de `web` (2 réplicas) no ns `tipsbank-web`, com Service ClusterIP. O `nginx.conf` do `apps/web/` faz proxy reverso para as APIs via hostname de Service — você vai ter que **ajustar os upstreams** no `nginx.conf` pra refletir os nomes FQDN inter-namespace (`api-contas.tipsbank-contas.svc.cluster.local:8080` etc.). Reempacote a imagem ou monte o `nginx.conf` via ConfigMap — as duas abordagens são válidas.

Você **vai** ter problema de imagem privada se usou registry privado. Use um Secret do tipo **`dockerconfigjson`** (Day-8) e referencie em `imagePullSecrets`.

**Critérios de aceite**:
- `kubectl get pods -A | grep tipsbank` mostra todos em `Running 2/2` (STS 1/1 para o Postgres, web 2/2)
- `kubectl port-forward -n tipsbank-transacoes svc/api-transacoes 8080:8080` e uma transferência funciona via API
- `kubectl port-forward -n tipsbank-web svc/web 8080:8080` e a SPA abre no browser com login funcionando
- `kubectl describe pod` de qualquer workload mostra `imagePullSecrets` configurado se o registry for privado

---

## Etapa 1.5 — ConfigMap, Secret e pod multicontainer

**Objetivo**: `api-transacoes` vira **pod multicontainer** com um sidecar de log que lê um arquivo gravado pela app.

**Revise antes**: Day-2 (multicontainer, EmptyDir), Day-8 (ConfigMap + Secret)

**Passo a passo**:
1. Faça o container principal da `api-transacoes` escrever um log em arquivo `/var/log/app/app.log` (você pode adicionar um handler de log em arquivo no `main.py`, ou usar `tee` via command override — qualquer abordagem vale)
2. Adicione um **sidecar** `log-forwarder` no mesmo pod. Use imagem `busybox` ou similar (assinada também, se quiser consistência) que roda `tail -F /var/log/app/app.log`
3. Compartilhe o volume `emptyDir` montado em `/var/log/app` nos dois containers
4. Mova **todas** as credenciais para Secret Opaque (DB_URL) e **todas** as URLs para ConfigMap
5. Garanta que os nomes dos Secrets/ConfigMaps são diferentes entre os 3 namespaces (**não compartilhe** recursos entre namespaces)

**Critérios de aceite**:
- `kubectl get pod <pod-transacoes> -o yaml` mostra 2 containers
- `kubectl logs -c log-forwarder <pod>` mostra o log estruturado da app
- Nenhuma variável sensível aparece diretamente no `Deployment.yaml` — tudo via `secretKeyRef` e `configMapKeyRef`

---

## Etapa 1.6 — PV NFS para a auditoria

**Objetivo**: `auditoria` passa a gravar os eventos em um **PV com NFS** acessado por ambas as réplicas ao mesmo tempo (RWX).

**Revise antes**: Day-6 completo

**Passo a passo**:
1. Suba um servidor NFS no cluster. Recomendado: StatefulSet `nfs-ganesha` ou use um nó externo com `nfs-kernel-server`.
2. Crie um **PV** do tipo NFS apontando para o servidor (Day-6 ensina o YAML exato)
3. Crie um **PVC** no namespace `tipsbank-auditoria` com `accessModes: [ReadWriteMany]`
4. Altere o Deployment da `auditoria` para montar esse PVC em `/data`
5. Escale para 3 réplicas
6. Dispare várias transferências e inspecione o arquivo `/data/eventos-YYYY-MM-DD.jsonl` — as 3 réplicas devem estar escrevendo no mesmo arquivo sem se atropelarem

**Armadilha**: como a app faz `open("a")` por escrita, o NFS precisa suportar locking. Documente no `EVIDENCIAS.md` se você observou algum conflito.

**Critérios de aceite**:
- `kubectl get pv,pvc -A` mostra o PV Bound ao PVC correto
- `kubectl exec -n tipsbank-auditoria <pod-1> -- ls /data` e `<pod-2> -- ls /data` listam os mesmos arquivos
- Após 100 transferências, a soma das linhas em todos os arquivos bate com o número de eventos disparados

---

## Checkpoint Semana 1

- [ ] Cluster kubeadm 3-nodes Ready
- [X] 3 imagens Distroless, Trivy limpo, Cosign assinado
- [ ] Apps rodando como 4 Deployments + 1 STS (postgres) nos 4 namespaces
- [ ] ConfigMap + Secret + Pod multicontainer + EmptyDir funcionando
- [ ] PV NFS servindo a auditoria com RWX

---

# SEMANA 2 — Exposição e Segurança de Rede

> **Objetivo da semana**: expor o TipsBank ao mundo via Ingress Nginx com TLS, replicar a app no EKS, e aplicar NetworkPolicies zero-trust entre namespaces.

---

## Etapa 2.1 — Ingress Nginx + múltiplos hosts

**Objetivo**: Ingress Nginx instalado e rotas funcionando para 2 hosts principais: `app.tipsbank.local` (SPA, entrada do usuário final) e `api.tipsbank.local` (acesso direto às 3 APIs via paths, útil para testes fora do frontend).

**Revise antes**: Day-9 completo

**Passo a passo**:
1. Instale o Ingress Nginx Controller (Helm ou manifest oficial)
2. Configure o `/etc/hosts` local apontando os hosts para o IP do controller
3. Crie os recursos `Ingress`:
   - Host `app.tipsbank.local` → `svc/web` (ns `tipsbank-web`) — esta é a rota que o usuário final acessa, servindo a SPA
   - Host `api.tipsbank.local` com paths:
     - `/contas/*` → `svc/api-contas` (ns `tipsbank-contas`)
     - `/transacoes/*` → `svc/api-transacoes` (ns `tipsbank-transacoes`)
     - `/auditoria/*` → `svc/auditoria` (ns `tipsbank-auditoria`)
4. Configure o `ingressClassName: nginx` em todos — é o que liga o recurso Ingress ao Controller certo (importante em clusters com múltiplos Controllers)
5. Teste: `curl -H 'Host: app.tipsbank.local' http://<ip-controller>/` retorna HTML da SPA; `curl -H 'Host: api.tipsbank.local' http://<ip-controller>/contas/contas` lista as contas

**Trade-off: proxy no `web` vs Ingress com paths**: o `nginx.conf` do próprio `web` já implementa proxy reverso para as 3 APIs. Em Kubernetes, a prática **preferida** é usar Ingress com paths (`/contas/*`, `/transacoes/*`, `/auditoria/*`) em vez de proxy no frontend — você elimina um hop, usa as Services nativamente e centraliza TLS/rate limit/auth no Ingress. Dito isso, se você optar por manter o proxy no `web` por simplicidade (menos recursos de Ingress para manter), também é válido — desde que documente a escolha no `EVIDENCIAS.md`.

**Critérios de aceite**:
- `kubectl get ingress -A` mostra os Ingress com address preenchido
- `curl -H 'Host: app.tipsbank.local' http://<ip-controller>/` retorna o HTML da SPA
- `curl -H 'Host: api.tipsbank.local' http://<ip-controller>/contas/contas` lista as contas
- `/etc/hosts` do seu laptop tem as entradas correspondentes

---

## Etapa 2.2 — TLS com cert-manager + recursos avançados do Ingress

**Objetivo**: HTTPS funcionando com cert-manager. Auth básica em `/admin`. Rate limit. Affinity Cookie em transações.

**Revise antes**: Day-10 completo

**Passo a passo**:
1. Instale o cert-manager via Helm
2. Crie um **ClusterIssuer** (self-signed para lab local; se você tiver domínio público pode usar Let's Encrypt staging)
3. Adicione `tls:` nos 3 Ingresses e referencie o Issuer via annotation
4. Para a rota `api.tipsbank.local/transacoes/*` (api-transacoes):
   - Adicione **Affinity Cookie** (annotation `nginx.ingress.kubernetes.io/affinity: cookie`) — transferências da mesma sessão caem no mesmo pod
5. Para `app.tipsbank.local` (frontend):
   - Adicione **Rate limit** global de 50 req/s (`nginx.ingress.kubernetes.io/limit-rps`) — rate limit no frontend faz sentido como proteção geral de entrada
6. Para a rota `api.tipsbank.local/contas/admin`:
   - Proteja com **Basic Auth** (Secret com htpasswd, annotation `auth-type: basic`)
   - Testar: `curl` sem credencial → 401; com credencial → 200
7. Documente o teste de **Upstream Hashing** em uma das rotas

**Critérios de aceite**:
- `curl -k https://app.tipsbank.local/` retorna 200 (HTML da SPA)
- `curl -k https://api.tipsbank.local/contas/admin/contas` → 401 sem credencial, 200 com
- Rajada de 100 requests com `hey` ou `ab` em `app.tipsbank.local` mostra retornos 429 após o rate limit

---

## Etapa 2.3 — Cluster EKS paralelo

**Objetivo**: o mesmo TipsBank rodando em um cluster **EKS** criado via EKSCTL. Apenas a app e o Ingress, não precisa (ainda) replicar policies.

**Revise antes**: Day-9 (parte EKS), Day-11 (EKSCTL)

**Passo a passo**:
1. Instale `awscli` e `eksctl` se ainda não tem
2. `eksctl create cluster --name tipsbank --nodes 2 --node-type t3.medium`
3. Configure seu `~/.kube/config` com **contexts** nomeados: `kubeadm-local` e `eks-tipsbank` (Day-9 ensina)
4. Instale o Ingress Nginx Controller no EKS (vai criar um NLB)
5. Aplique todos os manifests da Semana 1 e 2.1-2.2 no EKS
6. Aponte um domínio real para o NLB (ou use o hostname temporário da AWS)
7. **Economize**: destrua o cluster quando não estiver testando (`eksctl delete cluster`)

**Critérios de aceite**:
- `kubectl config get-contexts` mostra dois contexts funcionando
- `kubectl --context eks-tipsbank get nodes` retorna os nodes do EKS
- O TipsBank está acessível via HTTPS com DNS real

---

## Etapa 2.4 — Canary de transações

**Objetivo**: publicar `api-transacoes:v2` e roteá-la via **Canary Ingress** — 10% do tráfego vai para v2, o resto para v1.

**Revise antes**: Day-10 (Canary Deployment com Ingress)

**Passo a passo**:
1. No `apps/api-transacoes/main.py`, altere `APP_VERSION` em tempo de build para `v2` ou adicione um endpoint novo (ex: `/pix` que retorna mock)
2. Build + push + sign: `tipsbank-api-transacoes:v2.0.0`
3. Crie um segundo Deployment `api-transacoes-v2` no mesmo namespace, com label `version=v2`
4. Crie um segundo Service apontando para essa label
5. Crie um **Ingress canário** (annotation `nginx.ingress.kubernetes.io/canary: "true"` + `canary-weight: "10"`) apontando para o Service v2, compartilhando o mesmo host
6. Dispare 1000 requests e meça a proporção — deve ser aproximadamente 900/100

**Critérios de aceite**:
- `curl -s https://api.tipsbank.local/transacoes/health/live` retorna `version: v1` ou `version: v2` em proporção ~9:1 (o frontend continua chamando por trás e o split é transparente para o usuário final da SPA)
- `kubectl rollout undo` funciona em qualquer um dos Deployments
- O Canary também pode ser direcionado por header `X-Canary: true` (extra)

---

## Etapa 2.5 — NetworkPolicy zero-trust

**Objetivo**: aplicar uma **default-deny** em cada namespace e liberar **apenas** o tráfego estritamente necessário.

**Revise antes**: Day-17 completo

**Passo a passo**:
1. Em cada ns (`tipsbank-contas`, `tipsbank-transacoes`, `tipsbank-auditoria`, `tipsbank-web`): aplique uma NetworkPolicy `default-deny` (ingress + egress)
2. Libere egress DNS em todos (porta 53 TCP/UDP para o kube-dns)
3. Libere:
   - Ingress Controller → `web` (porta 8080) — entrada principal do usuário final
   - Ingress Controller → `api-contas`, `api-transacoes`, `auditoria` (porta 8080) — acesso direto via `api.tipsbank.local`
   - `web` (ns tipsbank-web) → `api-contas`, `api-transacoes`, `auditoria` (porta 8080) — **somente** se você optou por manter o proxy reverso no nginx do `web`; caso contrário, o `web` **não** precisa de egress para nenhuma API (só DNS + Ingress)
   - `api-transacoes` (ns tipsbank-transacoes) → `api-contas` (ns tipsbank-contas) porta 8080
   - `api-transacoes` → `auditoria` (ns tipsbank-auditoria) porta 8080
   - `api-contas` → `postgres-primary` (mesmo ns) porta 5432
   - `auditoria` → `nfs-server` porta 2049
4. Use **ipBlock com except** para bloquear a CIDR de management do cluster saindo dos pods (Day-17)
5. Valide com `kubectl exec` tentando `curl` para lugares não permitidos — deve dar timeout

**Nota sobre o `tipsbank-web`**: se você decidir mudar para Ingress puro com paths (sem proxy reverso no `nginx.conf` do `web`), a NetPol do `tipsbank-web` fica drasticamente mais simples — só aceita ingress do Ingress Controller na porta 8080 e só libera DNS no egress. Nenhuma rota para as APIs é necessária, já que o tráfego passa direto pelo Ingress Controller e cai nas Services das APIs. Documente a escolha no `EVIDENCIAS.md`.

**Armadilha**: o Flannel (default em muitos labs) **não** suporta NetworkPolicy. Se você não tem Calico ou Cilium no Semana 1, volta e troca o CNI. No EKS, use o add-on de NetworkPolicy.

**Critérios de aceite**:
- `kubectl exec -n tipsbank-auditoria <pod> -- curl api-contas.tipsbank-contas:8080` → **timeout** (não está na whitelist)
- `kubectl exec -n tipsbank-transacoes <pod> -- curl api-contas.tipsbank-contas:8080/health/live` → 200
- Tentativa de sair do cluster para um IP não permitido (ex: 169.254.169.254 no EKS) → bloqueado

---

## Checkpoint Semana 2

- [ ] Ingress Nginx com 3 hosts + HTTPS válido
- [ ] Rate limit, Auth e Affinity Cookie funcionando
- [ ] Cluster EKS paralelo com a app rodando
- [ ] Canary 90/10 entre v1 e v2 de transações
- [ ] NetworkPolicy zero-trust em 3 namespaces

---

# SEMANA 3 — Resiliência, Scheduling, Autoscaling e Observabilidade

> **Objetivo da semana**: tornar o TipsBank resiliente (probes, affinity) e observável (kube-prometheus), com HPA escalando sob carga gerada pelo Locust.

---

## Etapa 3.1 — Probes completas

**Objetivo**: todas as APIs com **3 probes** (liveness, readiness, startup) e o Postgres com liveness + readiness customizadas.

**Revise antes**: Day-4 (Probes)

**Passo a passo**:
1. A app expõe `/health/live`, `/health/ready` e `/health/startup` — use cada um no probe correto
2. Startup probe com `failureThreshold: 30, periodSeconds: 5` (dá 2.5 min para o container subir)
3. Liveness com `periodSeconds: 10`, readiness com `5`
4. No Postgres, use `pg_isready` como probe (Day-4)
5. O **`web`** também precisa de probes: o nginx expõe `/healthz` (liveness e readiness apontam para esse path na porta 8080)
6. Teste: kill manual do processo da app (`kubectl exec ... kill 1`) → probe reinicia o container

**Critérios de aceite**:
- `kubectl describe pod` mostra as 3 probes configuradas
- `kubectl get events` mostra evento `Killing` + `Started` quando você mata o processo
- Nenhuma API entra em CrashLoopBackOff durante deploy (prova que o startup probe está generoso o suficiente)

---

## Etapa 3.2 — Rollout strategy e rollback

**Objetivo**: configurar estratégia de rollout com `maxSurge` e `maxUnavailable` explícitos, testar rollback.

**Revise antes**: Day-3 (rollout, rollback)

**Passo a passo**:
1. Em `api-transacoes`, defina `strategy.rollingUpdate.maxSurge: 1, maxUnavailable: 0`
2. Faça um deploy de uma versão propositalmente quebrada (ex: `v1.9.9` com crash no startup)
3. Observe: com `maxUnavailable: 0` + startup probe falhando, o rollout **para** e mantém a versão antiga servindo
4. Execute `kubectl rollout undo deployment/api-transacoes`
5. Configure `revisionHistoryLimit: 5`

**Critérios de aceite**:
- Rollout quebrado não derruba tráfego (você consegue fazer requests durante)
- `kubectl rollout history` mostra pelo menos 3 revisões
- `kubectl rollout undo` volta a versão e o pod fica Ready

---

## Etapa 3.3 — Affinity, AntiAffinity, Taints e Tolerations

**Objetivo**: garantir que **réplicas de uma mesma API ficam em nodes diferentes** e que o Postgres primary/replica ficam em nodes separados.

**Revise antes**: Day-16 completo

**Passo a passo**:
1. Em todos os Deployments com >1 réplica, configure **podAntiAffinity** `preferredDuringSchedulingIgnoredDuringExecution` para espalhar por nodes
2. Crie um segundo StatefulSet `postgres-replica` (pode ser uma réplica streaming real ou apenas um STS separado com o mesmo dump — didático). Use `requiredDuringScheduling` + AntiAffinity com o primary
3. Adicione um **taint** `compliance=strict:NoSchedule` em 1 dos workers
4. Adicione **tolerations** apenas nos pods do Postgres → eles vão para esse node isolado
5. Valide: `kubectl get pods -o wide` mostra distribuição esperada

**Critérios de aceite**:
- `kubectl get pods -o wide -n tipsbank-contas | grep postgres` → primary e replica em nodes diferentes
- Pods de API sem toleration **não** vão para o node com taint
- `kubectl describe node <tainted>` confirma o taint

---

## Etapa 3.4 — Resources, Limits e QoS

**Objetivo**: 100% dos containers com `resources.requests` e `resources.limits` definidos, gerando QoS classes previsíveis.

**Revise antes**: Day-2 (limites de CPU/Memória)

**Passo a passo**:
1. Adicione resources em todos os containers (incluindo sidecar):
   - APIs: `requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 500m, memory: 256Mi}`
   - Sidecar log-forwarder: `requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}`
   - Postgres: `requests: {cpu: 250m, memory: 512Mi}, limits: {cpu: 1, memory: 1Gi}`
2. Verifique que `kubectl describe pod` mostra **QoS Class: Burstable** ou Guaranteed, não BestEffort

**Critérios de aceite**:
- Nenhum pod com `QoSClass: BestEffort`
- `kubectl top pod` (depois do Metrics Server na etapa 3.6) mostra uso real batendo com os requests

---

## Etapa 3.5 — Observabilidade: kube-prometheus + Grafana

**Objetivo**: kube-prometheus-stack instalado, Grafana acessível via Ingress, ServiceMonitor funcionando para as 3 APIs.

**Revise antes**: Day-11 completo, Day-12 completo

**Passo a passo**:
1. Crie o namespace `tipsbank-monitoring`
2. Instale o **kube-prometheus-stack** via Helm (versão oficial)
3. Exponha o Grafana via Ingress em `grafana.tipsbank.local` com TLS
4. Crie **ServiceMonitor** para cada API (apontando para `/metrics` porta 8080)
5. Crie um **PodMonitor** para o sidecar de log (se ele expuser métricas) — se não expuser, documente por que
6. **ServiceMonitor para o `web`** é **opcional**: o `nginx-unprivileged` não expõe métricas Prometheus nativamente. Se quiser coletar métricas do nginx, habilite o módulo `stub_status` no `nginx.conf` e adicione um **nginx-prometheus-exporter** como sidecar (ou cliente externo). Não é obrigatório para a entrega.
6. Importe (ou crie) um dashboard no Grafana mostrando:
   - Requests/s por endpoint
   - Latência p50/p95/p99
   - Status code distribution
   - Uso de CPU/Memória por pod

**Critérios de aceite**:
- Prometheus UI em `prometheus.tipsbank.local` mostra targets das 3 APIs como `UP`
- Dashboard Grafana renderiza com dados reais
- Alertmanager UI funcional (mesmo sem alertas ativos ainda)

---

## Etapa 3.6 — PrometheusRule com alertas de SLO

**Objetivo**: 4 alertas críticos configurados e disparando em teste.

**Revise antes**: Day-12 (PrometheusRule)

**Passo a passo**:
Crie os seguintes alertas:

| Alerta | Condição | Severity |
|---|---|---|
| `TipsBankApiDown` | `up{job=~"api-.*"} == 0` por 2min | critical |
| `TipsBankP99Alto` | p99 > 500ms por 5min | warning |
| `TipsBankErroAltoApi` | taxa de 5xx > 5% por 3min | critical |
| `TipsBankPodCrashLoop` | `kube_pod_container_status_restarts_total` > 3 em 10min | warning |

Teste cada um provocando a condição (mate uma API, jogue carga pesada, etc.) e capture screenshot do alerta no Alertmanager.

**Critérios de aceite**:
- Os 4 alertas aparecem em `kubectl get prometheusrule -A`
- Todos disparam quando a condição é provocada (evidência no `EVIDENCIAS.md`)

---

## Etapa 3.7 — HPA + Metrics Server + Locust stress test

**Objetivo**: HPA em cada API escalando sob carga real gerada pelo Locust.

**Revise antes**: Day-14 completo

**Passo a passo**:
1. Instale o **Metrics Server** no cluster kubeadm (no EKS costuma vir ou ser instalado via add-on)
2. Crie 3 HPAs:
   - `api-contas`: min 2, max 10, **métrica CPU 70%**
   - `api-transacoes`: min 3, max 15, **ContainerResource** CPU 70% no container `app` (exclui sidecar) — Day-14 ensina essa métrica
   - `auditoria`: min 2, max 6, **Memory 75%**
   - **HPA opcional também no `web`**: min 2, max 6, CPU 70% — útil quando o site explode no Black Friday do TipsBank e a quantidade de sessões/SPA cresce
3. Configure `scaleUp` e `scaleDown` com behavior customizado (Day-14)
4. Faça build da imagem Locust (pasta `locust/`) com o `locustfile.py`
5. Suba o Locust como **Deployment** no cluster apontando para `http://api-transacoes.tipsbank-transacoes:8080`
6. Exponha Locust UI via Ingress `locust.tipsbank.local`
7. Rode um teste de **5 minutos com 200 usuários** — observe HPA escalando no Grafana

**Critérios de aceite**:
- `kubectl get hpa -A` mostra os 3 HPAs com métricas ativas
- Durante o stress test, réplicas de `api-transacoes` sobem para >5
- Erro rate no Locust fica abaixo de 1%
- Após o teste, scaleDown traz as réplicas de volta em até 10 min

---

## Etapa 3.8 — DaemonSet de coleta

**Objetivo**: um DaemonSet em todos os workers coletando métricas (ou só logando eventos do node) — qualquer propósito didático vale.

**Revise antes**: Day-4 (DaemonSet)

**Passo a passo**:
1. Crie um DaemonSet simples que roda em cada worker. Pode ser:
   - `node-exporter` (se ainda não foi instalado pelo kube-prometheus)
   - Ou um container custom `busybox` que fica imprimindo `hostname` e uso de disco a cada 30s
2. Aplique tolerations para rodar inclusive em nodes com o taint `compliance=strict`

**Critérios de aceite**:
- `kubectl get ds -A` mostra um DS com `DESIRED == CURRENT == READY` igual ao número de workers

---

## Checkpoint Semana 3

- [ ] 3 probes em todas as APIs
- [ ] Rollout strategy + rollback testado
- [ ] AntiAffinity + Taints/Tolerations + QoS classes corretas
- [ ] kube-prometheus-stack + 4 alertas disparando
- [ ] 3 HPAs com métricas diferentes
- [ ] Locust gerando 200 users, HPA reagindo
- [ ] DaemonSet rodando em todos os workers

---

# SEMANA 4 — Compliance, RBAC, Helm e Entrega Final

> **Objetivo da semana**: aplicar compliance de banco via Kyverno, segregar acessos com RBAC (certificados + SA/Token), empacotar TUDO num Helm Chart umbrella.

---

## Etapa 4.1 — Kyverno: Validate (proibir root, proibir latest)

**Objetivo**: **nenhum** pod consegue ser criado com `runAsUser: 0` ou `image: *:latest`.

**Revise antes**: Day-15 completo

**Passo a passo**:
1. Instale Kyverno via Helm
2. Crie `ClusterPolicy` `disallow-root-user` — Validate, enforce mode
3. Crie `ClusterPolicy` `disallow-latest-tag` — Validate, enforce mode
4. Crie `ClusterPolicy` `require-labels` — exige labels `app`, `team`, `env` em todos os Deployments/STS/DS
5. **Teste que funciona**: tente aplicar um pod ruim — `kubectl apply` deve ser **rejeitado**:
   ```bash
   kubectl run ruim --image=nginx:latest
   # Error from server: admission webhook "validate.kyverno.svc-fail" denied the request
   ```

**Critérios de aceite**:
- `kubectl get cpol` mostra 3 policies no estado `ready: true`
- 3 tentativas de pods "ruins" ficam no `EVIDENCIAS.md` com a mensagem de rejeição do Kyverno
- Todos os pods existentes do TipsBank passam (se não passam, você tem label faltando)

---

## Etapa 4.2 — Kyverno: Mutate (injetar securityContext)

**Objetivo**: Kyverno **injeta automaticamente** `runAsNonRoot: true`, `readOnlyRootFilesystem: true` e `allowPrivilegeEscalation: false` em qualquer pod novo.

**Revise antes**: Day-15 (Policy Mutate)

**Passo a passo**:
1. Crie `ClusterPolicy` `mutate-security-context` do tipo Mutate
2. Teste criando um pod nginx simples: inspecione o resultado com `kubectl get pod nginx -o yaml` e veja os campos injetados
3. Suas imagens Distroless já são não-root (UID 65532). O `readOnlyRootFilesystem` pode quebrar algumas coisas — use **PolicyException** ou configure volumes `emptyDir` para paths que precisam de escrita

**Critérios de aceite**:
- Pod criado sem securityContext recebe o contexto mutado pelo Kyverno
- Todas as 3 APIs do TipsBank continuam funcionando com root filesystem read-only

---

## Etapa 4.3 — Kyverno: Generate (NetworkPolicy automática por namespace)

**Objetivo**: quando **qualquer** namespace novo é criado, o Kyverno cria automaticamente uma NetworkPolicy default-deny nele.

**Revise antes**: Day-15 (Policy Generate)

**Passo a passo**:
1. Crie `ClusterPolicy` `generate-default-deny-netpol`
2. Teste: `kubectl create namespace teste-deny`
3. Verifique que a NetworkPolicy foi gerada sozinha no novo namespace

Adicione também uma policy que **obriga** imagens a virem só do seu registry (Day-15 — proibir registries não confiáveis).

**Critérios de aceite**:
- `kubectl create ns novo-teste` gera automaticamente uma NetPol lá dentro
- Tentativa de usar imagem de registry externo (ex: `docker.io/nginx`) é rejeitada, mas `ghcr.io/seu-user/*` passa

---

## Etapa 4.4 — RBAC: 4 perfis com certificados X.509

**Objetivo**: 4 usuários humanos com certificado próprio e permissões diferentes.

**Revise antes**: Day-18 completo

**Passo a passo**:
Crie os 4 perfis abaixo, cada um com sua **chave privada + CSR + certificado aprovado pela CA do cluster** (Day-18 ensina o fluxo inteiro):

| Usuário | Role | Permissões |
|---|---|---|
| `operador-contas` | Role no ns `tipsbank-contas` | get/list/watch pods e logs |
| `operador-transacoes` | Role no ns `tipsbank-transacoes` | get/list/watch pods, logs, exec |
| `auditor-global` | ClusterRole | get/list/watch em pods e logs em **todos** os namespaces (readonly) |
| `sre` | ClusterRole cluster-admin | tudo (use com cuidado) |

Gere um `kubeconfig` para cada um e coloque em `evidencias/kubeconfigs/`. **Não faça commit das chaves privadas** — inclua no `.gitignore`.

Adicione também **2 ServiceAccounts com Token** (Day-18) usadas pelas próprias APIs quando elas precisarem falar com a API do K8s (se aplicável — ou crie um ServiceAccount por pod mesmo que ele não use, para praticar).

**Critérios de aceite**:
- `kubectl --kubeconfig=op-contas.kubeconfig get pods -n tipsbank-contas` → 200
- `kubectl --kubeconfig=op-contas.kubeconfig get pods -n tipsbank-transacoes` → **Forbidden**
- `kubectl --kubeconfig=auditor.kubeconfig get pods -A` → lista todos
- `kubectl --kubeconfig=auditor.kubeconfig delete pod X` → **Forbidden** (readonly)

---

## Etapa 4.5 — Helm Chart umbrella

**Objetivo**: **um único** `helm install tipsbank` sobe o banco inteiro (app + monitoring + policies) num cluster vazio.

**Revise antes**: Day-19 completo

**Passo a passo**:
1. Crie `helm/tipsbank/Chart.yaml` com version 1.0.0
2. Estruture em **subcharts** ou **templates**:
   - `templates/contas/` (Deployment, Service, Secret, ConfigMap)
   - `templates/transacoes/` (idem + sidecar + canary opcional)
   - `templates/auditoria/` (Deployment, PVC, Service)
   - `templates/web/` (Deployment, Service, ConfigMap do `nginx.conf`)
   - `templates/postgres/` (StatefulSet, Headless)
   - `templates/nfs/` (StatefulSet NFS)
   - `templates/monitoring/` (ServiceMonitor, PrometheusRule)
   - `templates/rbac/` (Roles, CRBs)
   - `templates/policies/` (Kyverno ClusterPolicies)
3. `values.yaml` com defaults sensatos
4. `values-dev.yaml` e `values-prod.yaml` sobrescrevendo imagem tag, réplicas, recursos
5. Use `_helpers.yaml` com funções como `tipsbank.fullname`, `tipsbank.labels` (Day-19)
6. Use `IF`, `RANGE`, `TOYAML`, `NINDENT`, `DEFAULT` nos templates
7. **Publique o chart** num repositório Helm remoto (pode ser GitHub Pages, OCI no ghcr.io, ou ChartMuseum) — Day-19 ensina
8. Teste instalação em um cluster **limpo**:
   ```bash
   helm repo add tipsbank https://seu-user.github.io/helm-charts
   helm install tipsbank tipsbank/tipsbank -n tipsbank --create-namespace -f values-prod.yaml
   ```

**Critérios de aceite**:
- `helm lint` passa limpo
- `helm template` renderiza todos os manifests corretamente
- Instalação num cluster limpo sobe **tudo** em menos de 10 min
- `helm upgrade` funciona sem derrubar tráfego (rolling update preservado)
- `helm rollback` também
- Chart publicado num repositório remoto acessível

---

## Etapa 4.6 — Teste de compliance final

**Objetivo**: rodar uma checklist de compliance como se fosse auditoria do BACEN.

**Revise antes**: todos os Days

**Passo a passo**:
Execute cada comando abaixo e **cole o output** no `EVIDENCIAS.md`:

```bash
# 1. Nenhuma imagem fora do registry confiável
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | grep -v 'ghcr.io/seuuser\|quay.io/jetstack\|registry.k8s.io\|gcr.io/distroless'

# 2. Nenhum pod rodando como root
kubectl get pods -A -o json | jq '[.items[] | select(.spec.securityContext.runAsUser == 0 or (.spec.containers[].securityContext.runAsUser // 0) == 0) | .metadata.name]'

# 3. Cobertura de probes
kubectl get deploy,sts,ds -A -o json | jq '[.items[] | select(.spec.template.spec.containers[].livenessProbe == null) | .metadata.name]'

# 4. Cobertura de resources
kubectl get deploy,sts,ds -A -o json | jq '[.items[] | select(.spec.template.spec.containers[].resources.limits == null) | .metadata.name]'

# 5. Policies Kyverno ativas
kubectl get cpol -o json | jq '.items[] | {name: .metadata.name, ready: .status.ready}'

# 6. NetworkPolicies aplicadas nos namespaces tipsbank-*
kubectl get netpol -n tipsbank-contas
kubectl get netpol -n tipsbank-transacoes
kubectl get netpol -n tipsbank-auditoria

# 7. Imagens assinadas (Cosign)
for img in ghcr.io/seuuser/tipsbank-api-contas:v1.0.0 ghcr.io/seuuser/tipsbank-api-transacoes:v1.0.0 ghcr.io/seuuser/tipsbank-auditoria:v1.0.0; do
  cosign verify $img --certificate-identity-regexp '.*' --certificate-oidc-issuer-regexp '.*' && echo "OK: $img"
done
```

Todos devem retornar limpo (sem pods/resources fora de compliance) e "OK" nas assinaturas.

**Nota sobre o `web` e o critério de compliance de imagem**: o `web` roda com `nginx-unprivileged` (Alpine, user uid 101) — é **nonroot e minimal**, mas **não** é "Distroless" no sentido técnico estrito (tem shell do Alpine, por exemplo). O critério "100% Distroless" deve ser lido como "100% das APIs Python são Distroless; o `web` é alternativa didática nonroot/minimal". Documente essa nuance no `EVIDENCIAS.md`. Os demais critérios (não rodar root, não usar `:latest`, ter `resources` definidos, ter probes) **aplicam-se integralmente** ao `web`.

**Critérios de aceite**:
- Os 7 comandos colados no `EVIDENCIAS.md` com saída esperada
- Registro de 3 tentativas de aplicar manifest "ruim" e ver o Kyverno bloqueando
- Nuance do `web` (nonroot/minimal, não Distroless propriamente dito) documentada

---

## Etapa 4.7 — Vídeo demo final

**Objetivo**: gravar um vídeo de **10-15 minutos** mostrando o desafio concluído.

**Passo a passo**:
O vídeo deve mostrar, em ordem:
1. `helm install tipsbank` num cluster limpo
2. Todos os pods subindo em `kubectl get pods -A --watch`
3. Acesso ao Grafana com métricas reais
4. Uma transferência funcionando via `curl https://app.tipsbank.local`
5. Locust gerando carga + HPA escalando no Grafana
6. Tentativa de deploy de um pod ruim sendo bloqueada pelo Kyverno
7. Canary v1/v2 em ação (com split 90/10 visível)
8. Um dos 4 usuários RBAC tentando ação não autorizada e sendo bloqueado
9. Rollback de um deploy
10. Encerramento com `helm uninstall`

**Critérios de aceite**:
- Vídeo acessível (link público/unlisted)
- Todos os 10 pontos acima aparecem
- Áudio audível e explicação do que está sendo mostrado

---

## Checkpoint final (todas as semanas)

- [ ] 4 imagens Distroless/minimal, 0 HIGH/CRITICAL, assinadas com Cosign (3 APIs Distroless + `web` nginx-unprivileged nonroot/minimal)
- [ ] Cluster kubeadm 3-nodes + Cluster EKS paralelo
- [ ] Helm Chart umbrella instalando **tudo** num cluster limpo
- [ ] 3 Kyverno Policies (Validate + Mutate + Generate) ativas
- [ ] 4 perfis RBAC com certificados, validados
- [ ] NetworkPolicy zero-trust em todos os ns
- [ ] kube-prometheus-stack + 4 alertas + dashboards
- [ ] 3 HPAs + Locust stress test passando
- [ ] Canary 90/10 entre v1 e v2
- [ ] Vídeo demo final publicado
- [ ] `EVIDENCIAS.md` com outputs, prints e justificativas

---

## Depois de submeter

A nota final tem 3 componentes:
1. **Funcional** (60%): todos os critérios de aceite satisfeitos
2. **Qualidade** (30%): código limpo, YAMLs bem organizados, Helm Chart idiomático
3. **Apresentação** (10%): clareza do vídeo, qualidade do `EVIDENCIAS.md`

Forma exata de validação automatizada será divulgada pelo instrutor. Prepare-se para rodar um script de verificação contra seu cluster vivo.

---

**Boa sorte. Você está mais preparado do que imagina.**
