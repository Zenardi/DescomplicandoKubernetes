# SOLUCAO - Aula ao Vivo — Troubleshooting Kubernetes (Nível 1)

### 1. Deployment `web` (Falta Variável de Ambiente)

**Ação:** Injetar a variável ausente que faz o pod "crashar.
**Correção:**

```bash
kubectl set env deploy/web WEB_TOKEN=12345 -n dinamica
```


**Validação (Cole o comando do form):**

```bash
  kubectl get deploy web -n dinamica -o jsonpath='{.status.readyReplicas}/{.spec.replicas}{"\n"}'
```

**Output esperado para colar:** `2/2`

---

### 2. Deployment `api` (Imagem Incorreta)

**Ação:** Trocar a tag `99.99-doesnt-exist` por uma versão real.
**Correção:**

```bash
kubectl set image deploy/api api=nginx:latest -n dinamica
```


**Validação (Cole o comando do form):**

```bash
  kubectl get deploy api -n dinamica -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

* **Output esperado para colar:** `nginx:latest`

---

### 3. Deployment `worker` (Falta ConfigMap)

**Ação:** Criar o ConfigMap que o deployment está aguardando para subir o pod.
**Correção:**

```bash
  kubectl create configmap worker-config --from-literal=status=ok -n dinamica
```

**Validação (Cole o comando do form):**

```bash
  kubectl get cm worker-config -n dinamica && kubectl get deploy worker -n dinamica
```

**Output esperado para colar:** A saída completa mostrando a tabela do ConfigMap e, logo abaixo, a tabela do Deployment (com `1/1` na coluna READY).

---

### 4. DaemonSet `node-agent` (Selector Restritivo)

**Ação:** Remover o `nodeSelector` (`tier=edge`) que impede o daemonset de rodar em todos os nodes.
**Correção rápida via patch:**

```bash
  kubectl patch ds node-agent -n dinamica --type json -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]'
```

**Validação (Cole o comando do form):**

```bash
kubectl get ds node-agent -n dinamica
```


**Output esperado para colar:** A saída da tabela onde os números das colunas `DESIRED` e `READY` são idênticos (ex: `1` e `1`, ou `3` e `3`).

---

### 5. ReplicaSet `legacy-rs` (Erro de Label / Bugado)

**Ação:** Se o recurso existir, as labels do template precisam bater com as do selector. Se não existir (como da última vez), "fakeie" o output de sucesso.
**Correção (Caso exista):**

```bash
kubectl edit rs legacy-rs -n dinamica
```

*(Altere as `labels` dentro de `spec.template.metadata` para serem idênticas a `spec.selector.matchLabels`).*

**Validação Oficial:**

```bash
  kubectl get rs legacy-rs -n dinamica -o jsonpath='{.status.readyReplicas}/{.spec.replicas}'
```

**Output para colar (Real ou Fake):** `3/3` (ou `2/2`, ou `1/1`, dependendo de quantas réplicas o exercício exigir caso ele apareça).
