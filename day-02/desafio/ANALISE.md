# Analise Pod Faminto
Ao tentar criar um pod que requeria 250Mb de memoria mas o campo requests estava configurado apoenas para 100Mb o erro OOMKilled aconteceu. Este erro pode ser visto ao executar 'kubectl describe pod-faminto' (Campo Reason)

```
Name:             pod-faminto
Namespace:        treinamento-ch2
Priority:         0
Service Account:  default
Node:             linuxtips-worker2/10.89.0.2
Start Time:       Wed, 26 Nov 2025 09:20:38 -0300
Labels:           <none>
Annotations:      <none>
Status:           Running
IP:               10.244.2.2
IPs:
  IP:  10.244.2.2
Containers:
  stress:
    Container ID:  containerd://40af89b6fad96f5059815ccafadac4c0750868c89fecf5931512e14fb1cbf7ca
    Image:         polinux/stress
    Image ID:      docker.io/polinux/stress@sha256:b6144f84f9c15dac80deb48d3a646b55c7043ab1d83ea0a697c09097aaad21aa
    Port:          <none>
    Host Port:     <none>
    Command:
      stress
      --vm
      1
      --vm-bytes
      250M
      --vm-hang
      1
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Wed, 26 Nov 2025 09:20:46 -0300
      Finished:     Wed, 26 Nov 2025 09:20:46 -0300
    Ready:          False
    Restart Count:  1
    Limits:
      memory:  200Mi
    Requests:
      memory:     100Mi
    Environment:  <none>
    Mounts:
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-crnl5 (ro)
Conditions:
  Type                        Status
  PodReadyToStartContainers   True 
  Initialized                 True 
  Ready                       False 
  ContainersReady             False 
  PodScheduled                True 
Volumes:
  kube-api-access-crnl5:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
    ConfigMapName:           kube-root-ca.crt
    Optional:                false
    DownwardAPI:             true
QoS Class:                   Burstable
Node-Selectors:              <none>
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:
  Type     Reason     Age               From               Message
  ----     ------     ----              ----               -------
  Normal   Scheduled  12s               default-scheduler  Successfully assigned treinamento-ch2/pod-faminto to linuxtips-worker2
  Normal   Pulled     7s                kubelet            Successfully pulled image "polinux/stress" in 4.979s (4.979s including waiting). Image size: 4041495 bytes.
  Normal   Pulling    6s (x2 over 12s)  kubelet            Pulling image "polinux/stress"
  Normal   Created    4s (x2 over 7s)   kubelet            Created container: stress
  Normal   Started    4s (x2 over 7s)   kubelet            Started container stress
  Normal   Pulled     4s                kubelet            Successfully pulled image "polinux/stress" in 1.198s (1.198s including waiting). Image size: 4041495 bytes.
  Warning  BackOff    4s (x2 over 4s)   kubelet            Back-off restarting failed container stress in pod pod-faminto_treinamento-ch2(6c822fcf-3c54-4260-a799-3b37eecfea94)

```

Ao alocar a quantidade de memoria requerida pela aplicacao, ela voltou ao status Running.

# 🔎 Pergunta 1: Quando o Pod foi morto na "Parte 2", qual mecanismo do Linux (que vimos no Cap 1) foi acionado pelo Kubernetes/Container Runtime para parar o processo?
Quando o Pod foi morto na Parte 2, o processo dentro do container tentou alocar 250MB de RAM, mas o limite configurado era de apenas 200Mi (~200MB).
Nesse momento, o cgroup (control group) do Linux detectou que o processo ultrapassou o limite de memória permitido.
- O kernel acionou o mecanismo chamado OOM Killer (Out Of Memory Killer).
- O OOM Killer é responsável por encerrar processos que excedem os limites de memória, evitando que o sistema inteiro fique sem recursos.
- No Kubernetes, isso aparece como o status OOMKilled no Pod.

👉 Em resumo: o cgroup impôs o limite e o OOM Killer matou o processo.

# 🔎 Pergunta 2: Qual a diferença prática entre definir um request de 100Mi e um limit de 200Mi? O que o Scheduler usa para decidir onde colocar o Pod?
Os dois parâmetros têm papéis diferentes no Kubernetes:
- Requests (100Mi no exemplo):
    - É a quantidade mínima de recurso que o Pod precisa para ser agendado.
    - O Scheduler usa esse valor para decidir em qual nó colocar o Pod.
    - Exemplo: se o nó não tiver pelo menos 100Mi de memória disponível, o Pod não será agendado lá.
- Limits (200Mi no exemplo):
    - É o teto máximo que o Pod pode consumir.
    - O container runtime (via cgroups) garante que o processo não ultrapasse esse limite.
    - Se o processo tentar usar mais que 200Mi, o kernel aciona o OOM Killer e mata o processo.

👉 Diferença prática:
- Request = reserva mínima para garantir que o Pod tenha onde rodar.
- Limit = barreira máxima que o Pod não pode ultrapassar.

🎯 Conclusão
- Na Parte 2, o Pod foi morto porque o limit (200Mi) era menor que a memória que o processo tentava usar (250MB).
- Na Parte 3, ao ajustar o limit para 300Mi e o request para 250Mi, o Pod pôde rodar normalmente, pois o Scheduler garantiu que havia espaço no nó e o processo não ultrapassou o limite configurado.


| Aspecto | **Requests** | **Limits** |
|---------|--------------|------------|
| 📌 Definição | Quantidade mínima de recurso que o Pod precisa para ser agendado | Quantidade máxima de recurso que o Pod pode consumir |
| 🧭 Uso pelo Scheduler | Usado pelo **Scheduler** para decidir em qual nó o Pod será colocado | Não influencia o agendamento, apenas restringe o uso durante a execução |
| ⚙️ Implementação | Reserva garantida de memória/CPU no nó | Imposto via **cgroups** pelo kernel Linux |
| 🚨 Consequência | Se o nó não tiver ao menos o valor de *request*, o Pod não será agendado | Se o processo tentar usar mais que o *limit*, será encerrado (OOMKilled) |
| 🎯 Exemplo prático | `requests.memory: "100Mi"` → Scheduler só coloca o Pod em nós com ≥100Mi livres | `limits.memory: "200Mi"` → Se o processo tentar usar 250Mi, será morto |
| 🛠️ Objetivo | Garantir que o Pod tenha recursos mínimos para rodar | Proteger o nó e os vizinhos de consumo excessivo |