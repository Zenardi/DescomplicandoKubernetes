# KUBEBANK - ARCHITECTURE DECISION RECORD (ADR)

- [KUBEBANK - ARCHITECTURE DECISION RECORD (ADR)](#kubebank---architecture-decision-record-adr)
  - [SEÇÃO 1: SEGURANÇA DA CADEIA DE SUPRIMENTOS](#seção-1-segurança-da-cadeia-de-suprimentos)
    - [1.1. Decisão: Imagem Base do Container](#11-decisão-imagem-base-do-container)
    - [1.2. Decisão: Pipeline de Segurança (CI/CD)](#12-decisão-pipeline-de-segurança-cicd)
    - [1.3. Decisão: Integridade e Assinatura](#13-decisão-integridade-e-assinatura)
  - [SEÇÃO 2: ESTRATÉGIA DE ACESSO](#seção-2-estratégia-de-acesso)
    - [2.1. Decisão: Exposição do Serviço e Ingress Controller](#21-decisão-exposição-do-serviço-e-ingress-controller)
    - [2.2. Decisão: Gerenciamento de Certificados (TLS)](#22-decisão-gerenciamento-de-certificados-tls)
    - [2.3. Decisão: Objeto de Roteamento](#23-decisão-objeto-de-roteamento)
  - [SEÇÃO 3: OBSERVABILIDADE TOTAL](#seção-3-observabilidade-total)
    - [3.1. Decisão: Coleta de Métricas (Scraping)](#31-decisão-coleta-de-métricas-scraping)
    - [3.2. Decisão: Alertas e Notificações](#32-decisão-alertas-e-notificações)
  - [SEÇÃO 4: RESILIÊNCIA, DISPONIBILIDADE E GOVERNANÇA](#seção-4-resiliência-disponibilidade-e-governança)
    - [4.1. Decisão: Governança de Recursos (Policy as Code)](#41-decisão-governança-de-recursos-policy-as-code)
    - [4.2. Decisão: Probes e Health Checks](#42-decisão-probes-e-health-checks)
- [Resumo Técnico da Implementação](#resumo-técnico-da-implementação)


| Campo | Detalhes |
| --- | --- |
| **ID** | ADR-001 |
| **Título** | Definição da Arquitetura de Segurança, Acesso, Observabilidade e Resiliência - CashFlow API |
| **Status** | Aceito |
| **Data** | 09 de Fevereiro de 2026 |
| **Autores** | Squad de Arquitetura Cloud Native (SWD/ARC-CN) |
| **Contexto** | O projeto KubeBank necessita definir a arquitetura para a aplicação crítica `CashFlow API`. Este documento responde à Solicitação de Proposta Técnica (RFP) focando em segurança da cadeia de suprimentos (Supply Chain Security), modernização do Ingress com Traefik, observabilidade completa e governança de recursos via Policy-as-Code. |


---

## SEÇÃO 1: SEGURANÇA DA CADEIA DE SUPRIMENTOS

**Contexto:** A imagem atual baseada em `ubuntu:latest` foi rejeitada pela segurança devido ao alto número de CVEs e superfície de ataque desnecessária.

### 1.1. Decisão: Imagem Base do Container

* **Escolha:** Utilizar imagens **Distroless** (Google) ou **Wolfi** (Chainguard).

**Justificativa:**
  * **Redução de Superfície de Ataque:** Estas imagens não contêm shell (`/bin/sh`, `/bin/bash`) nem gerenciadores de pacotes (`apt`, `apk`). Isso impede que atacantes instalem ferramentas ou executem comandos arbitrários caso explorem uma vulnerabilidade na aplicação.
  * **Menos CVEs:** Por conterem apenas o estritamente necessário para o runtime (ex: JRE, glibc mínima), a quantidade de vulnerabilidades conhecidas é drasticamente menor que uma imagem OS completa como Ubuntu ou Alpine padrão.



### 1.2. Decisão: Pipeline de Segurança (CI/CD)

* **Escolha:** Implementar **Trivy** (Aqua Security).

* **Justificativa:**
  * O Trivy deve rodar no pipeline como um passo bloqueante ("Quality Gate"). Ele escaneia tanto o sistema operacional quanto as dependências de código (go.mod, pom.xml, package.json).
  * **Política:** Se vulnerabilidades de nível `CRITICAL` ou `HIGH` forem encontradas e tiverem correção disponível, o build falha e a imagem não é enviada ao registry.



### 1.3. Decisão: Integridade e Assinatura

* **Escolha:** Utilizar **Cosign** (Projeto Sigstore).

**Justificativa:**
  * Garantia de procedência. A imagem será assinada criptograficamente no momento do push.
  * No cluster, usaremos um Admission Controller para verificar essa assinatura. Isso impede que imagens maliciosas ou não autorizadas (que não passaram pelo pipeline do KubeBank) sejam implantadas.



---

## SEÇÃO 2: ESTRATÉGIA DE ACESSO

**Contexto:** O Banco Central exige criptografia em trânsito (HTTPS). O antigo padrão de NGINX Ingress será substituído por uma alternativa mais moderna e segura.

### 2.1. Decisão: Exposição do Serviço e Ingress Controller

* **Escolha:** Utilizar **Traefik Proxy** como Ingress Controller.

**Justificativa:**
  * **Segurança e Manutenção:** Diferente do NGINX Ingress (community) que teve falhas de segurança recentes e desafios de manutenção, o Traefik é ativamente mantido e seguro por padrão.
  * **Recursos Nativos:** Suporte nativo a Middlewares (Rate Limiting, Circuit Breaker, Compressão) via CRDs, simplificando configurações complexas que antes exigiam annotations extensas.
  * **Observabilidade:** Dashboard nativo para visualização de rotas e status dos backends.



### 2.2. Decisão: Gerenciamento de Certificados (TLS)

* **Escolha:** **Cert-Manager** integrado com Let's Encrypt.

**Justificativa:**
  * Automação total do ciclo de vida dos certificados TLS (emissão e renovação).
  * O Cert-Manager cria os `Secrets` do Kubernetes contendo os certificados válidos, garantindo HTTPS sem intervenção manual.



### 2.3. Decisão: Objeto de Roteamento

* **Escolha:** **Ingress** (Padrão Kubernetes) ou **IngressRoute** (CRD do Traefik).

**Justificativa:**
  * Recomendamos o uso do CRD **IngressRoute** do Traefik para maior poder de configuração (middlewares, TCP/UDP routing).
  * Este objeto define o roteamento baseado em *Host* (`api.kubebank.com`) e *Path* (`/cashflow`), encaminhando o tráfego para o Service da aplicação.



---

## SEÇÃO 3: OBSERVABILIDADE TOTAL

**Contexto:** A equipe de Ops usa a stack Prometheus. É necessário garantir que métricas sejam coletadas tanto a nível de serviço quanto a nível de pod, e que alertas sejam disparados em caso de falha.

### 3.1. Decisão: Coleta de Métricas (Scraping)

* **Escolha:** Implementar **ambos**: **ServiceMonitor** E **PodMonitor**.

**Justificativa:**
  * **ServiceMonitor:** Coleta métricas através do endpoint do Service. Ideal para visualizar a saúde geral da aplicação e balanceamento de carga global.
  * **PodMonitor:** Coleta métricas diretamente de cada Pod individualmente.
  * *Por que ambos?* O `PodMonitor` é crucial para cenários de debug onde apenas *uma* réplica do pod está degradada (ex: memory leak em uma instância específica), algo que a média do ServiceMonitor poderia mascarar.





### 3.2. Decisão: Alertas e Notificações

* **Escolha:** Componente **Alertmanager** configurado via **PrometheusRule**.

**Justificativa:**
  * O **PrometheusRule** é um CRD que permite definir regras de alerta como código (Infrastructure as Code).
  * Se uma métrica violar um limiar (ex: `rate(http_requests_total{status="500"}[5m]) > 1%`), o Prometheus dispara o alerta para o **Alertmanager**, que notificará a equipe via Slack/PagerDuty.



---

## SEÇÃO 4: RESILIÊNCIA, DISPONIBILIDADE E GOVERNANÇA

**Contexto:** A aplicação é pesada na inicialização e consome muita memória. Precisamos garantir que ela não afete outros vizinhos e que o Kubernetes respeite seu tempo de boot.

### 4.1. Decisão: Governança de Recursos (Policy as Code)

* **Escolha:** Utilizar **Kyverno** para impor *Limits* e *Requests*.

**Justificativa:**
  * Para evitar OOMKill no nó (Node OOM), cada Pod deve ter seu "contrato" de memória definido.
  * **Implementação:** Criaremos uma `ClusterPolicy` no Kyverno em modo `enforce`. Qualquer tentativa de deploy de um Pod sem `resources.requests` e `resources.limits` definidos será rejeitada automaticamente pela API do Kubernetes.



### 4.2. Decisão: Probes e Health Checks

* **Escolha:** **StartupProbe** e **ReadinessProbe** (Validados via **Kyverno**).

**Justificativa:**
  * **StartupProbe:** Configurado para tolerar a inicialização lenta (30s+). Ex: `failureThreshold: 30`, `periodSeconds: 2`. Impede que o Liveness mate o container durante o boot.
  * **ReadinessProbe:** Garante que o tráfego só seja enviado quando a conexão com o banco estiver estabelecida.
  * **Governança:** A mesma política do Kyverno exigirá a presença desses probes nos manifestos para garantir a resiliência desde o "Day 1".



---

# Resumo Técnico da Implementação

| Área | Tecnologia/Conceito | Benefício Chave |
| --- | --- | --- |
| **Imagem Base** | Wolfi / Distroless | Segurança máxima (Zero-CVE base). |
| **Ingress** | Traefik Proxy | Modernidade, segurança e Middlewares nativos. |
| **Observabilidade** | ServiceMonitor + PodMonitor | Visão macro (serviço) e micro (pod/instância). |
| **Alertas** | PrometheusRule | Alertas versionados como código. |
| **Policy Engine** | Kyverno | Obrigatoriedade de Limits, Requests e Probes. |
| **Security CI** | Trivy + Cosign | Scan de vulnerabilidades e Assinatura digital. |