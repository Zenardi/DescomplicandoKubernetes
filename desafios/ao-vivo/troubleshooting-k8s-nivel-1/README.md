# Aula ao Vivo — Troubleshooting Kubernetes (Nível 1)

Diagnostique e corrija um cluster Kubernetes com múltiplos workloads quebrados. Você tem 60 minutos.

* Duração: 60 min

* Tentativas: 2

* Janela aberta até: 08/06/2026


## O que você vai fazer

## Sua missão

Um cluster Kubernetes está com **5 workloads quebrados**. Você é o engineer de plantão chamado pra arrumar antes que alguém acorde o time todo. Você tem **60 minutos**.

## O que você precisa fazer

1. Investigar o que está quebrado em cada workload
2. Corrigir os problemas — usando kubectl edit, kubectl apply, criando Secret/ConfigMap faltante, etc
3. Validar que os pods sobem e ficam Ready
4. Submeter quando tudo estiver de pé

## Checklist do que você vai encontrar

* [ ] Deployment `web` — pods em CrashLoopBackOff. Algo falta no env.
* [ ] Deployment `api` — ImagePullBackOff. Imagem com tag errada.
* [ ] Deployment `worker` — pods em Pending. ConfigMap referenciado não existe.
* [ ] DaemonSet `node-agent` — só roda em metade dos nodes. Selector ou tolerations.
* [ ] ReplicaSet órfão `legacy-rs` — selector divergente do template.

## Comandos que vão te salvar

```bash
kubectl get pods -A
kubectl describe pod <name>
kubectl logs <pod> --previous
kubectl get deployments,rs,ds
kubectl explain deployment.spec.template.spec.containers
```


## Regras

* Não pode apagar e recriar workload do zero — isso conta como cheat. A IA detecta.
* Pode pedir ajuda pros colegas no Meet — mas é cada um no seu lab.
* Quando tudo estiver Ready (kubectl get pods -A mostrando Running), clica em Submeter que a IA faz double-check.


## Tarefas

* Deployment web está com 2 pods Ready
    ```sh
    kubectl get deployment web -o jsonpath="{.status.readyReplicas}"
    ```

* Deployment api está com 1 pod Ready (imagem correta)
    ```sh
    kubectl get deployment api -o yaml | grep image:
    ```

* Deployment worker está com pods Ready (ConfigMap criado)
    ```sh
    kubectl get configmap worker-config && kubectl get deployment worker
    ```

* DaemonSet node-agent rodando em todos os nodes
    ```sh
    kubectl get ds node-agent — DESIRED == CURRENT == READY
    ```

* ReplicaSet legacy-rs com pods Ready (selector batendo)
    ```sh
    kubectl describe rs legacy-rs
    ```


## Regras

* 60 minutos a partir do clique em "Iniciar agora".
* 2 tentativas no total dentro da janela de validade.
* Ao concluir com aprovação, ganha a skill kubernetes-troubleshooting-l1 e 250 XP.
* Se sua conta GitHub estiver conectada ao Mesa, o relatório vai pro seu repositório de workspace automaticamente.