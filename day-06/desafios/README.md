- [Desafios](#desafios)
    - [Exercício 1: Criando uma StorageClass para AWS EBS (gp3)](#exercício-1-criando-uma-storageclass-para-aws-ebs-gp3)
    - [Exercício 2: Provisionamento Dinâmico (Dynamic Provisioning) com PVC](#exercício-2-provisionamento-dinâmico-dynamic-provisioning-com-pvc)
    - [Exercício 3: Consumindo o Volume em um Pod](#exercício-3-consumindo-o-volume-em-um-pod)
    - [Exercício 4: Alterando a Política de Retenção (Reclaim Policy)](#exercício-4-alterando-a-política-de-retenção-reclaim-policy)
    - [Exercício 5: Expandindo um Volume (Resizing)](#exercício-5-expandindo-um-volume-resizing)
- [Desafios Nivel HARD!](#desafios-nivel-hard)
    - [Exercício 6: StatefulSets e Identidade de Armazenamento Persistente](#exercício-6-statefulsets-e-identidade-de-armazenamento-persistente)
    - [Exercício 7: Volume Snapshots (Backup e Restore)](#exercício-7-volume-snapshots-backup-e-restore)
    - [Exercício 8: Volume Cloning (Clonagem de PVC)](#exercício-8-volume-cloning-clonagem-de-pvc)
    - [Exercício 9: Acesso Compartilhado com EFS (ReadWriteMany)](#exercício-9-acesso-compartilhado-com-efs-readwritemany)
    - [Exercício 10: Criptografia de Dados com KMS](#exercício-10-criptografia-de-dados-com-kms)

# Desafios 

---

### Exercício 1: Criando uma StorageClass para AWS EBS (gp3)

**Cenário:** O cluster padrão pode vir com uma classe de armazenamento `gp2`, mas você quer garantir performance e custos otimizados usando volumes do tipo `gp3` (General Purpose SSD de nova geração).

**Tarefa:**

1. Crie um manifesto YAML para uma nova `StorageClass` chamada `aws-sc-fast`.
2. O provisioner deve ser o driver CSI da AWS (`ebs.csi.aws.com`) ou o in-tree (`kubernetes.io/aws-ebs`), dependendo da versão do seu cluster (prefira o CSI se estiver no EKS recente).
3. Defina o parâmetro de tipo como `gp3`.
4. Garanta que a política de *Reclaim* seja `Delete` e que o modo de *Binding* seja `WaitForFirstConsumer` (para garantir que o volume seja criado na mesma zona de disponibilidade do Pod).

**Objetivo:** Entender como definir classes de armazenamento personalizadas e parâmetros específicos da nuvem.

---

### Exercício 2: Provisionamento Dinâmico (Dynamic Provisioning) com PVC

**Cenário:** Uma aplicação web precisa de 5Gi de armazenamento persistente.

**Tarefa:**

1. Crie um arquivo YAML para um `PersistentVolumeClaim` chamado `web-pvc`.
2. Solicite **5Gi** de armazenamento.
3. Aponte para a `StorageClass` criada no Exercício 1 (`aws-sc-fast`) usando a anotação ou campo `storageClassName`.
4. Aplique o YAML no cluster.
5. **Verificação:** Execute `kubectl get pvc` e `kubectl get pv`.
* *Dica:* Se você usou `WaitForFirstConsumer` no exercício anterior, o status do PVC ficará como `Pending` até que um Pod tente usá-lo. Isso é esperado!



**Objetivo:** Praticar a criação de solicitações de volume e entender o comportamento do provisionamento dinâmico.

---

### Exercício 3: Consumindo o Volume em um Pod

**Cenário:** Você precisa subir um servidor Nginx que utilize o volume solicitado para salvar seus logs ou arquivos HTML.

**Tarefa:**

1. Crie um Pod chamado `nginx-storage-pod`.
2. Use a imagem `nginx:latest`.
3. Monte o PVC `web-pvc` (do Exercício 2) no caminho `/usr/share/nginx/html`.
4. Aplique o manifesto.
5. **Ação:** Entre no pod (`kubectl exec -it nginx-storage-pod -- /bin/bash`) e crie um arquivo dentro de `/usr/share/nginx/html/index.html` com o texto "Olá Kubernetes Storage".
6. Delete o Pod e recrie-o. Verifique se o arquivo ainda existe.

**Objetivo:** Entender como montar volumes em containers e verificar a persistência dos dados além do ciclo de vida do Pod.

---

### Exercício 4: Alterando a Política de Retenção (Reclaim Policy)

**Cenário:** Por padrão, quando você deleta um PVC provisionado dinamicamente, o volume na AWS (EBS) também é deletado (devido à política `Delete`). Porém, para dados críticos, você quer evitar a perda acidental.

**Tarefa:**

1. Identifique o nome do **PersistentVolume (PV)** que foi criado automaticamente para o seu `web-pvc` (use `kubectl get pv`).
2. Edite esse PV (`kubectl edit pv <nome-do-pv>`) e altere a `persistentVolumeReclaimPolicy` de `Delete` para `Retain`.
3. Delete o **PVC** (`kubectl delete pvc web-pvc`). O Pod deve ser deletado antes ou o PVC ficará preso em "Terminating".
4. Verifique o status do PV. Ele deve estar como `Released` (ou `Available` dependendo da versão/config), mas o volume EBS na AWS **não** deve ser excluído.

**Objetivo:** Aprender a proteger dados alterando políticas de retenção e entender a diferença entre deletar um objeto Kubernetes e o recurso físico na nuvem.

---

### Exercício 5: Expandindo um Volume (Resizing)

**Cenário:** O espaço de 5Gi ficou pequeno e a aplicação precisa de 10Gi.

**Tarefa:**

1. Primeiro, certifique-se que sua `StorageClass` (do Exercício 1) possui a flag `allowVolumeExpansion: true`. Se não tiver, edite-a para adicionar.
2. Recrie o PVC `web-pvc` (se você o deletou no ex 4, terá que refazer o processo de ligação ou criar um novo e apontar para um novo Pod). Vamos assumir um PVC ativo e ligado a um PV.
3. Edite o PVC e altere o campo `resources.requests.storage` de `5Gi` para `10Gi`.
4. Aplique a alteração.
5. Verifique se o tamanho foi atualizado (pode ser necessário reiniciar o Pod ou aguardar o driver CSI processar a mudança no sistema de arquivos).

**Objetivo:** Praticar a redimensionamento de volumes, uma tarefa comum de "Dia 2" na operação de clusters.


# Desafios Nivel HARD!

Estes exercícios assumem que você está utilizando um cluster com o driver **AWS EBS CSI** (para snapshots e cloning) e, para o exercício de EFS, o driver **AWS EFS CSI**.

---

### Exercício 6: StatefulSets e Identidade de Armazenamento Persistente

**Conceito:** Diferente de *Deployments*, os *StatefulSets* mantêm uma identidade fixa para cada Pod (web-0, web-1). Isso é crucial para bancos de dados ou sistemas distribuídos.

**Cenário:** Você precisa implantar um sistema distribuído onde cada réplica tenha seu próprio disco dedicado, que não deve ser compartilhado nem perdido se o Pod reiniciar.

**Tarefa:**

1. Crie um manifesto para um `StatefulSet` chamado `app-db`.
2. Use a imagem `mysql` ou `postgres`.
3. Em vez de criar PVCs manualmente, use a seção `volumeClaimTemplates` na especificação do StatefulSet.
4. Configure para ter **3 réplicas**.
5. Aplique o manifesto.
6. **Verificação:** Liste os PVCs (`kubectl get pvc`). Você deverá ver `data-app-db-0`, `data-app-db-1`, `data-app-db-2`.
7. **Teste de Persistência:** Delete o Pod `app-db-0`. O Kubernetes irá recriá-lo. Verifique se ele se liga automaticamente ao **mesmo** PVC `data-app-db-0` anterior, mantendo os dados.

---

### Exercício 7: Volume Snapshots (Backup e Restore)

**Conceito:** O Kubernetes permite padronizar a criação de snapshots de disco (AWS EBS Snapshots) através da API `VolumeSnapshot`. *Nota: Requer que os CRDs de Snapshot e o Snapshot Controller estejam instalados no cluster.*

```shell
# 1. Definição de Snapshot Classes
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.3/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml

# 2. Definição de Snapshot Contents
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.3/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml

# 3. Definição de Snapshots
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.3/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

# Instala o controller no namespace kube-system
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.3/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.3/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

# Verifique se o controlador subiu corretamente.
kubectl get pods -n kube-system -l app=snapshot-controller

---
NAME                                   READY   STATUS    RESTARTS   AGE
snapshot-controller-7d99fcf5cd-kpn56   1/1     Running   0          13s
snapshot-controller-7d99fcf5cd-lvgjx   1/1     Running   0          13s

```

**Cenário:** Você vai realizar uma manutenção arriscada no banco de dados e precisa garantir um ponto de restauração rápido.

**Tarefa:**

1. Crie uma `VolumeSnapshotClass` apontando para o driver `ebs.csi.aws.com`.
2. Crie um objeto `VolumeSnapshot` que referencie o PVC `web-pvc` (criado nos exercícios anteriores).
3. Aguarde o snapshot ficar `ReadyToUse` (verifique com `kubectl get volumesnapshot`). Isso criará um Snapshot real no console da AWS.
4. **Restore:** Crie um **novo** PVC chamado `web-pvc-restored`.
5. Na especificação desse novo PVC, adicione o campo `dataSource`, apontando para o `VolumeSnapshot` criado no passo 2.
6. Crie um Pod para montar esse novo PVC e verifique se os dados originais estão lá.

---

### Exercício 8: Volume Cloning (Clonagem de PVC)

**Conceito:** O recurso de clonagem permite provisionar um novo volume pré-populado com dados de um PVC existente, sem passar pelo processo de snapshot/restore manualmente.

**Cenário:** Sua equipe de QA precisa depurar um problema que ocorre na produção. Eles precisam de uma cópia exata e imediata dos dados atuais para um ambiente de teste isolado.

**Tarefa:**

1. Identifique um PVC existente com dados (ex: `web-pvc`).
2. Crie um arquivo YAML para um novo PVC chamado `pvc-clone-qa`.
3. Configure o `storageClassName` igual ao do volume original (deve ser o driver CSI da AWS).
4. Defina o `dataSource` apontando diretamente para o **PVC de origem** (`kind: PersistentVolumeClaim`, `name: web-pvc`).
5. Aplique e aguarde o provisionamento.
6. Monte o `pvc-clone-qa` em um novo Pod e confirme se os arquivos são idênticos aos da origem.

---

### Exercício 9: Acesso Compartilhado com EFS (ReadWriteMany)

**Conceito:** Volumes EBS são **ReadWriteOnce (RWO)** (apenas um node pode escrever por vez). Para que múltiplos pods em nodes diferentes escrevam no mesmo volume (ex: CMS Wordpress, processamento de arquivos em lote), você precisa de **ReadWriteMany (RWX)**. Na AWS, usa-se o EFS (Elastic File System).

**Cenário:** Você tem uma aplicação web escalada em 3 réplicas que precisam ler e gravar arquivos na mesma pasta `/uploads`.

**Tarefa:**

1. Crie um File System EFS na AWS (console ou CLI) e anote o ID (fs-xxxxxx).
2. Configure a `StorageClass` para o driver EFS (`efs.csi.aws.com`) passando o `fileSystemId` nos parâmetros ou use o modo de provisionamento dinâmico do driver EFS se configurado.
3. Crie um PVC com `accessModes: ["ReadWriteMany"]`.
4. Crie um *Deployment* com 2 ou mais réplicas montando esse mesmo PVC.
5. Entre em um pod, crie um arquivo, e verifique se ele aparece instantaneamente no outro pod.

---

### Exercício 10: Criptografia de Dados com KMS

**Conceito:** Compliance de segurança exige que dados em repouso sejam criptografados com chaves gerenciadas pelo cliente (KMS), e não apenas as chaves padrão da AWS.

**Cenário:** Criar uma classe de armazenamento segura para dados sensíveis.

**Tarefa:**

1. Crie (ou identifique) uma chave KMS na AWS e copie seu ARN.
2. Crie uma nova `StorageClass` chamada `aws-ebs-encrypted`.
3. Nos `parameters` da StorageClass, adicione:
   * `encrypted: "true"`
   * `kmsKeyId: "<ARN-da-sua-chave-KMS>"`


4. Crie um PVC usando essa classe.
5. Verifique no Console da AWS (seção EC2 -> Volumes) se o volume criado possui o status de criptografia "Encrypted" e se está usando a chave KMS correta (e não a `aws/ebs` padrão).