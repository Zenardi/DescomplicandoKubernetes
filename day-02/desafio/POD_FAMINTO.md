# O Mistério do Pod Faminto
## Contexto
Você é o Engenheiro DevOps responsável por implantar uma nova aplicação de processamento de dados chamada "StressApp". Os desenvolvedores avisaram que essa aplicação pode ser um pouco... "gulosa" com memória RAM.

Seu objetivo é implantar essa aplicação no cluster Kubernetes, mas você precisa garantir que ela não derrube o nó ou afete outros vizinhos. Para isso, você usará seus conhecimentos sobre Pods, Resources (Requests/Limits) e Namespaces.

# Missão
# Parte 1: Preparando o Terreno
1. Crie um Namespace chamado treinamento-ch2. Toda a sua atividade deve acontecer dentro dele para não bagunçar o cluster.
# Parte 2: O Teste de Estresse (O Erro Esperado)
2. Crie um manifesto YAML para um Pod com as seguintes especificações:

    - Name: pod-faminto
    - Image: polinux/stress
    - Namespace: treinamento-ch2
    - Command: O container deve rodar o comando stress --vm 1 --vm-bytes 250M --vm-hang 1. (Isso faz o container tentar alocar 250MB de RAM).
    - Resources:
    - Requests: memory: "100Mi"
    - Limits: memory: "200Mi"
3. Aplique esse manifesto no cluster.

4. Observe o status do Pod. O que aconteceu?
    - Use kubectl get pod -n treinamento-ch2 -w ou kubectl describe pod pod-faminto -n treinamento-ch2.
    - Procure pela razão da falha. Você deve ver algo relacionado a OOMKilled.

# Parte 3: A Correção
5. Agora, crie um novo manifesto (ou edite o anterior) para um Pod chamado pod-comportado.
6. Mantenha a mesma imagem e comando (stress --vm 1 --vm-bytes 250M --vm-hang 1).
7. Ajuste os Limits de memória para que sejam suficientes para o que a aplicação pede (lembre-se, ela quer 250MB). Dê uma margem de segurança.
8. Aplique o manifesto e verifique se o Pod fica com status Running.

# Perguntas para Reflexão (Responda mentalmente ou anote)
1. Quando o Pod foi morto na "Parte 2", qual mecanismo do Linux (que vimos no Cap 1) foi acionado pelo Kubernetes/Container Runtime para parar o processo?
2. Qual a diferença prática entre definir um request de 100Mi e um limit de 200Mi? O que o Scheduler usa para decidir onde colocar o Pod?
Dica: Lembre-se que containers são apenas processos isolados. Se um processo tenta usar mais memória do que o cgroup permite, o kernel entra em ação!

# Exemplos para o desafio
### pod-memory-leak.yaml
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-faminto
  namespace: treinamento-ch2
spec:
  containers:
  - name: stress
    image: polinux/stress
    # Tenta alocar 250MB de RAM
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
    resources:
      requests:
        memory: "100Mi"
      limits:
        # Limite de 200MB é menor que os 250MB que ele tenta alocar -> OOMKilled
        memory: "200Mi"
```

### pod-safe.yaml
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-comportado
  namespace: treinamento-ch2
spec:
  containers:
  - name: stress
    image: polinux/stress
    # Tenta alocar 250MB de RAM
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
    resources:
      requests:
        memory: "250Mi" # Ajustado para garantir que o nó tenha espaço
      limits:
        memory: "300Mi" # Limite superior aos 250MB necessários
```