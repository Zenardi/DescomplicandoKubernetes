Aqui está o **Gabarito Completo** para os exercícios de Storage no Kubernetes (AWS).

Sugiro criar um arquivo YAML separado para cada exercício (ex: `ex1.yaml`, `ex2.yaml`) para manter a organização.

---

# 🟢 Nível Básico

### Exercício 1: StorageClass AWS EBS (gp3)

Este manifesto cria a "receita" de bolo para o Kubernetes pedir discos rápidos e eficientes à AWS.

**Arquivo:** `ex1-storageclass.yaml`

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: aws-sc-fast
provisioner: ebs.csi.aws.com       # Usa o driver CSI moderno
volumeBindingMode: WaitForFirstConsumer # Só cria o disco quando souber a zona do Pod
reclaimPolicy: Delete              # Deleta o disco na AWS se deletar o PVC
allowVolumeExpansion: true         # Permite aumentar o tamanho depois
parameters:
  type: gp3                        # Tipo de disco SSD nova geração

```

*Comando:* `kubectl apply -f ex1-storageclass.yaml`

---

### Exercício 2: PersistentVolumeClaim (PVC)

Aqui fazemos o pedido do "ticket" de 5GB.

**Arquivo:** `ex2-pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: web-pvc
spec:
  accessModes:
    - ReadWriteOnce   # EBS só pode ser montado em um nó por vez
  storageClassName: aws-sc-fast
  resources:
    requests:
      storage: 5Gi

```

*Comando:* `kubectl apply -f ex2-pvc.yaml`
*Verificação:* `kubectl get pvc` (Deve estar `Pending` até você fazer o ex3).

---

### Exercício 3: Consumindo em um Pod

O Pod que vai usar o disco e destravar o PVC.

**Arquivo:** `ex3-pod.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-storage-pod
spec:
  containers:
  - name: nginx
    image: nginx:latest
    ports:
    - containerPort: 80
    volumeMounts:
    - mountPath: "/usr/share/nginx/html" # Onde o disco aparece dentro do container
      name: web-storage
  volumes:
  - name: web-storage
    persistentVolumeClaim:
      claimName: web-pvc

```

*Comando:* `kubectl apply -f ex3-pod.yaml`
*Teste:*

1. `kubectl exec -it nginx-storage-pod -- bash`
2. `echo "Olá Kubernetes Storage" > /usr/share/nginx/html/index.html`
3. `exit`
4. `kubectl delete pod nginx-storage-pod`
5. Recrie o pod e cheque se o arquivo existe.

---

### Exercício 4: Alterar Reclaim Policy

Protegendo o disco contra deleção acidental.

**Passos Manuais:**

1. Descubra o nome do PV: `kubectl get pv` (ex: `pvc-1234abcd...`).
2. Edite: `kubectl edit pv pvc-1234abcd...`.
3. Mude:
```yaml
persistentVolumeReclaimPolicy: Retain  # Mude de Delete para Retain

```


4. Teste: `kubectl delete pvc web-pvc`.
5. Resultado: O PV fica como `Released`, mas o disco na AWS continua lá intacto.

---

### Exercício 5: Expandindo o Volume

Aumentando de 5GB para 10GB.

**Passos:**

1. Se deletou o PVC no ex4, recrie-o e recrie o Pod.
2. Edite o PVC: `kubectl edit pvc web-pvc`.
3. Altere:
```yaml
resources:
  requests:
    storage: 10Gi # Era 5Gi

```


4. Salve.
5. Verifique: `kubectl get pvc`. Às vezes requer reiniciar o Pod para o sistema de arquivos (XFS/Ext4) expandir internamente, mas o objeto Kubernetes atualiza rápido.

---

# 🔴 Nível HARD

### Exercício 6: StatefulSet

Para bancos de dados, onde cada réplica tem seu próprio disco numerado.

**Arquivo:** `ex6-statefulset.yaml`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: app-db
spec:
  serviceName: "db-service"
  replicas: 3
  selector:
    matchLabels:
      app: database
  template:
    metadata:
      labels:
        app: database
    spec:
      containers:
      - name: postgres
        image: postgres:13
        env:
        - name: POSTGRES_PASSWORD
          value: "minhasenha"
        volumeMounts:
        - name: db-data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:  # <--- A mágica do StatefulSet
  - metadata:
      name: db-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: aws-sc-fast
      resources:
        requests:
          storage: 1Gi

```

*Resultado:* Serão criados PVCs `db-data-app-db-0`, `db-data-app-db-1`, etc.

---

### Exercício 7: Volume Snapshots

Tirando uma "foto" do disco para backup.

**Arquivo:** `ex7-snapshot.yaml`

```yaml
# 1. Classe de Snapshot
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: aws-snapshot-class
driver: ebs.csi.aws.com
deletionPolicy: Delete

---
# 2. O Snapshot em si
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: web-pvc-snapshot
spec:
  volumeSnapshotClassName: aws-snapshot-class
  source:
    persistentVolumeClaimName: web-pvc # Nome do PVC original

```

**Para Restaurar (Novo PVC):**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: web-pvc-restored
spec:
  storageClassName: aws-sc-fast
  dataSource:
    name: web-pvc-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi

```

---

### Exercício 8: Volume Cloning

Duplicando um volume instantaneamente sem snapshot.

**Arquivo:** `ex8-clone.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-clone-qa
spec:
  storageClassName: aws-sc-fast
  dataSource:
    name: web-pvc          # Aponta DIRETAMENTE para o PVC de origem
    kind: PersistentVolumeClaim
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi

```

*Nota:* O PVC de origem e o clone devem estar na mesma zona de disponibilidade.

---

### Exercício 9: EFS (ReadWriteMany)

Compartilhando arquivos entre vários pods.

**Pré-requisito:** Ter o ID do EFS (ex: `fs-0123abcd`) e o driver EFS CSI instalado.

**Arquivo:** `ex9-efs.yaml`

```yaml
# 1. StorageClass EFS
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-0123abcd # Substitua pelo seu ID real
  directoryPerms: "700"
---
# 2. PVC ReadWriteMany
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-claim
spec:
  accessModes:
    - ReadWriteMany # <--- Permite múltiplos acessos
  storageClassName: efs-sc
  resources:
    requests:
      storage: 5Gi
---
# 3. Deployment Consumidor
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-shared
spec:
  replicas: 2
  selector:
    matchLabels:
      app: shared-app
  template:
    metadata:
      labels:
        app: shared-app
    spec:
      containers:
      - name: app
        image: busybox
        command: ["/bin/sh", "-c", "while true; do date >> /mnt/shared/data.txt; sleep 5; done"]
        volumeMounts:
        - name: shared-storage
          mountPath: /mnt/shared
      volumes:
      - name: shared-storage
        persistentVolumeClaim:
          claimName: efs-claim

```

---

### Exercício 10: Criptografia KMS

Segurança máxima para os dados.

**Arquivo:** `ex10-encrypted-sc.yaml`

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: aws-ebs-encrypted
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
  kmsKeyId: "arn:aws:kms:us-east-1:123456789012:key/seu-hash-aqui" # Use o Output do Terraform

```

*Ao criar um PVC com essa classe, o volume na AWS nascerá criptografado.*