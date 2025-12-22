Use este codigo para provisionar um cluster Kubernetes na AWS para poder realizar os desafios.

- [O que este código cria:](#o-que-este-código-cria)
- [Pré-requisitos](#pré-requisitos)
- [Instruções Passo a Passo](#instruções-passo-a-passo)
  - [Notas para resolver os exercícios usando este ambiente:](#notas-para-resolver-os-exercícios-usando-este-ambiente)


# O que este código cria:
- VPC: Uma rede isolada.
- EKS Cluster: O cluster Kubernetes.
- EBS CSI Driver (Add-on): Essencial para os exercícios básicos e avançados 1, 2, 3 e 5. Ele já vem configurado com as permissões IAM (IRSA) necessárias.
- KMS Key: Uma chave de criptografia pronta para você usar no Exercício Avançado 5.
- EFS File System: O sistema de arquivos e os Security Groups necessários para o Exercício Avançado 4.
- Nodes: Um grupo de nós t3.medium.

# Pré-requisitos
- Terraform instalado.
- AWS CLI instalado e configurado (aws configure).
- kubectl instalado.

---

# Instruções Passo a Passo
1. Provisionar a Infraestrutura
Abra o terminal na pasta onde salvou o arquivo e execute:

    ```shell
    terraform init
    terraform apply -auto-approve
    ```
Isso levará cerca de 15 a 20 minutos.


2. Conectar ao Cluster
Após o Terraform terminar, ele mostrará um output verde. Copie e execute o comando de configuração que ele forneceu (algo como):

    ```shell
    aws eks --region us-east-1 update-kubeconfig --name k8s-storage-lab
    ```
Teste com: kubectl get nodes


3. Instalar os CRDs de Snapshot (Importante para o Exercicio Avançado 2)
O add-on do EKS instala o driver, mas frequentemente os CRDs (Definições de Recursos Personalizados) para Snapshots precisam ser aplicados manualmente para que o Kubernetes entenda o que é um VolumeSnapshot. Execute estes comandos:

    ```shell
    # Instala os CRDs de Snapshot
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

    # Instala o Snapshot Controller (o cérebro que gerencia os snapshots)
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
    ```


4. Instalar o Driver EFS (Apenas para o Exercicio Avançado 4)
O código Terraform criou o "Hardware" (o File System na AWS), mas seu cluster precisa do driver para conversar com ele. A forma mais fácil é via comando simples após o cluster estar de pé:

    ```shell
    kubectl apply -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.7"
    ```


## Notas para resolver os exercícios usando este ambiente:
Exercício 5 (Avançado): Use o valor de kms_key_arn que apareceu no final do Terraform (terraform output kms_key_arn) para configurar sua StorageClass criptografada.

Exercício 4 (Avançado): Use o valor de efs_id (terraform output efs_id) para configurar sua StorageClass EFS.

Quando terminar de estudar, não esqueça de destruir tudo para não ser cobrado:

```shell
terraform destroy -auto-approve
```

