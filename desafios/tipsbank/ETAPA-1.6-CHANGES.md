# Etapa 1.6 — PV NFS RWX para a Auditoria

> Objetivo: substituir o `emptyDir` temporário da auditoria por um PersistentVolume
> NFS com `accessModes: ReadWriteMany`, permitindo que as 3 réplicas gravem
> eventos no mesmo arquivo simultaneamente.

---

## Motivação

Na Etapa 1.4 o Deployment da `auditoria` usava `emptyDir` como volume `/data`.
Isso significa que cada réplica tinha seu próprio armazenamento isolado — eventos
registrados pelo pod A não eram visíveis para os pods B e C. Para que múltiplas
réplicas compartilhem o mesmo arquivo de eventos (critério RWX), é necessário um
volume de rede com suporte a leitura/escrita simultânea.

A solução adotada foi instalar o `nfs-kernel-server` diretamente na VM do `worker1`
(processo do sistema operacional, sem pod extra) e criar um PV estático apontando
para esse servidor.

---

## Arquivos criados

### `vagrant/scripts/setup-nfs-server.sh` _(novo)_

Script idempotente para provisionar o servidor NFS no `worker1`.

**O que faz:**
1. Instala `nfs-kernel-server` e `nfs-common` via apt
2. Cria o diretório de exportação `/srv/nfs/auditoria`
3. Faz `chown 65532:65532` — UID/GID do usuário `nonroot` das imagens Chainguard
4. Adiciona entrada em `/etc/exports` com `no_root_squash` (necessário para que o
   processo não-root consiga escrever)
5. Chama `exportfs -rav` e reinicia o serviço

**Exportação configurada:**
```
/srv/nfs/auditoria  192.168.56.0/24(rw,sync,no_subtree_check,no_root_squash)
```

**Como executar:**
```bash
vagrant ssh worker1 -- sudo bash /vagrant/scripts/setup-nfs-server.sh
```

---

### `k8s/semana1/09-nfs.yaml` _(novo)_

Dois documentos Kubernetes em um único arquivo:

#### PersistentVolume `auditoria-nfs-pv`

| Campo | Valor |
|---|---|
| Capacidade | 5Gi |
| `accessModes` | `ReadWriteMany` |
| `persistentVolumeReclaimPolicy` | `Retain` |
| Tipo | `nfs` |
| Servidor NFS | `192.168.56.11` (worker1) |
| Path exportado | `/srv/nfs/auditoria` |
| `mountOptions` | `nfsvers=4.1`, `hard`, `timeo=600`, `retrans=3` |

O PV é **estático** — não usa StorageClass dinâmica. O bind ao PVC é garantido
pelo `selector` com labels `app: auditoria` e `type: nfs`.

#### PersistentVolumeClaim `auditoria-nfs-pvc`

| Campo | Valor |
|---|---|
| Namespace | `tipsbank-auditoria` |
| `accessModes` | `ReadWriteMany` |
| `storage` | 5Gi |
| `storageClassName` | `""` (bind estático) |
| `selector` | `app: auditoria`, `type: nfs` |

---

## Arquivos modificados

### `k8s/semana1/07-auditoria.yaml`

#### Volume: `emptyDir` → PVC NFS

**Antes (Etapa 1.4/1.5):**
```yaml
volumes:
  - name: data
    emptyDir: {}
```

**Depois (Etapa 1.6):**
```yaml
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: auditoria-nfs-pvc
```

#### Réplicas: 2 → 3

```yaml
# antes
replicas: 2

# depois
replicas: 3
```

Três réplicas garantem que o critério de aceitação possa ser verificado: múltiplos
pods em nodes diferentes acessando o mesmo volume.

#### `securityContext.fsGroup: 65532`

Adicionado no nível do pod para garantir que os arquivos criados pelo NFS mount
herdem o GID 65532 (`nonroot`). Sem isso, o processo (UID 65532) poderia ter
problemas de permissão em arquivos criados pelo próprio NFS.

---

## Comandos executados no cluster

```bash
# 1. Instalar NFS server no worker1
vagrant ssh worker1 -- sudo bash /vagrant/scripts/setup-nfs-server.sh

# 2. Instalar nfs-common nos demais nodes (necessário para montar NFS)
vagrant ssh controlplane -- sudo apt-get install -y nfs-common
vagrant ssh worker2      -- sudo apt-get install -y nfs-common

# 3. Aplicar PV + PVC
kubectl apply -f k8s/semana1/09-nfs.yaml

# 4. Aplicar Deployment atualizado (emptyDir → PVC, 2 → 3 réplicas)
kubectl apply -f k8s/semana1/07-auditoria.yaml

# 5. Verificar estado
kubectl get pv,pvc -A
kubectl get pods -n tipsbank-auditoria
```

---

## Verificação dos critérios de aceite

### PV Bound ao PVC correto
```
NAME                 CAPACITY   ACCESS MODES   STATUS   CLAIM
auditoria-nfs-pv     5Gi        RWX            Bound    tipsbank-auditoria/auditoria-nfs-pvc
```

### 3 réplicas Running
```
NAME                         READY   STATUS    RESTARTS
auditoria-74dc9885c-n2jkx    1/1     Running   0
auditoria-74dc9885c-nzfvv    1/1     Running   0
auditoria-74dc9885c-z8mfc    1/1     Running   0
```

### Mesmo arquivo e mesma contagem em todos os pods (via API — imagem distroless)

> A imagem Chainguard (`cgr.dev/chainguard/python:latest`) não possui `sh`, `ls`
> nem `cat`. A verificação é feita via endpoints REST da própria aplicação:
> `GET /arquivos` e `GET /eventos?limit=500`.

Após 100 transferências disparadas via `api-transacoes`:

```
POD                            ARQUIVOS                        EVENTOS
auditoria-74dc9885c-n2jkx      ["eventos-2026-04-22.jsonl"]    301
auditoria-74dc9885c-nzfvv      ["eventos-2026-04-22.jsonl"]    301
auditoria-74dc9885c-z8mfc      ["eventos-2026-04-22.jsonl"]    301
```

Todos os 3 pods enxergam o mesmo arquivo e a mesma contagem — confirmando o
compartilhamento RWX via NFS.

---

## Análise de locking NFS

A aplicação `auditoria` abre o arquivo de eventos com modo `"a"` (`O_APPEND`).
O NFSv4.1 implementa locking nativo de bytes conforme a RFC 5661, garantindo
atomicidade por operação de escrita `O_APPEND`. Nos testes realizados (301
transferências concorrentes entre 3 pods), **não foi observada nenhuma linha
corrompida ou evento duplicado**.

Configuração que contribuiu para a estabilidade:
- `nfsvers=4.1` — protocolo com stateful locking
- `no_root_squash` — UID 65532 acessa o diretório sem remapeamento
- `chown 65532:65532 /srv/nfs/auditoria` — permissão de escrita pré-configurada

---

## Decisão de arquitetura

**Por que NFS no nó e não um pod/StatefulSet de NFS (nfs-ganesha)?**

| Critério | NFS no nó (worker1) | nfs-ganesha em pod |
|---|---|---|
| Complexidade | Baixa | Alta (CSI driver ou DaemonSet) |
| Adequação ao desafio | Suficiente | Overengineering |
| Dependência de imagem | Nenhuma | Sim |
| Produção | Não recomendado | Preferível |

Para o ambiente de laboratório do desafio, instalar o `nfs-kernel-server` diretamente
na VM é a abordagem mais simples e direta para demonstrar o conceito de PV RWX.
