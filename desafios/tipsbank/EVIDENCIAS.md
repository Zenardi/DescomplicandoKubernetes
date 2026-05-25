# TipsBank — Evidências de Entrega

- [TipsBank — Evidências de Entrega](#tipsbank--evidências-de-entrega)
  - [Etapa 1.2 — Justificativa: Dockerfile multi-stage + runtime Distroless nonroot](#etapa-12--justificativa-dockerfile-multi-stage--runtime-distroless-nonroot)
    - [Por que Dockerfile multi-stage?](#por-que-dockerfile-multi-stage)
    - [Por que imagem Distroless (sem shell, sem package manager)?](#por-que-imagem-distroless-sem-shell-sem-package-manager)
    - [Por que rodar como usuário não-root (UID 65532)?](#por-que-rodar-como-usuário-não-root-uid-65532)
  - [Trivy — Scan de vulnerabilidades (Etapa 1.2)](#trivy--scan-de-vulnerabilidades-etapa-12)
    - [Vulnerabilidades encontradas e corrigidas](#vulnerabilidades-encontradas-e-corrigidas)
    - [Resultado final — `trivy image --severity HIGH,CRITICAL`](#resultado-final--trivy-image---severity-highcritical)
      - [zenardi/tipsbank-api-contas:v1.0.0](#zenarditipsbank-api-contasv100)
      - [zenardi/tipsbank-api-transacoes:v1.0.0](#zenarditipsbank-api-transacoesv100)
      - [zenardi/tipsbank-auditoria:v1.0.0](#zenarditipsbank-auditoriav100)
      - [zenardi/tipsbank-web:v1.0.0](#zenarditipsbank-webv100)
  - [Docker Scout — Scan de vulnerabilidades (Etapa 1.2)](#docker-scout--scan-de-vulnerabilidades-etapa-12)
    - [Vulnerabilidades encontradas e corrigidas](#vulnerabilidades-encontradas-e-corrigidas-1)
    - [Resultado final — `docker scout cves zenardi/tipsbank-<app>:v1.0.0`](#resultado-final--docker-scout-cves-zenarditipsbank-appv100)
      - [zenardi/tipsbank-api-contas:v1.0.0](#zenarditipsbank-api-contasv100-1)
      - [zenardi/tipsbank-api-transacoes:v1.0.0](#zenarditipsbank-api-transacoesv100-1)
      - [zenardi/tipsbank-auditoria:v1.0.0](#zenarditipsbank-auditoriav100-1)
      - [zenardi/tipsbank-web:v1.0.0](#zenarditipsbank-webv100-1)
  - [Etapa 1.6 — PV NFS (RWX) e Locking de Arquivo Concorrente](#etapa-16--pv-nfs-rwx-e-locking-de-arquivo-concorrente)
    - [Configuração do NFS](#configuração-do-nfs)
    - [Teste de escrita concorrente](#teste-de-escrita-concorrente)
    - [Análise de locking NFS](#análise-de-locking-nfs)
  - [Etapa 3.6 — PrometheusRule com Alertas de SLO](#etapa-36--prometheusrule-com-alertas-de-slo)
    - [Alertas configurados](#alertas-configurados)
    - [Validação — PrometheusRule carregada pelo Prometheus Operator](#validação--prometheusrule-carregada-pelo-prometheus-operator)
    - [Teste de disparo dos alertas](#teste-de-disparo-dos-alertas)
      - [1. `TipsBankApiDown`](#1-tipsbankapidown)
      - [2. `TipsBankP99Alto`](#2-tipsbankp99alto)
    - [Alertas recebidos pelo Alertmanager](#alertas-recebidos-pelo-alertmanager)
  - [Semana 4](#semana-4)
    - [Etapa 4.1 — Kyverno: Validate (proibir root, proibir latest)](#etapa-41--kyverno-validate-proibir-root-proibir-latest)
    - [Etapa 4.2 — Kyverno: Mutate (injetar securityContext)](#etapa-42--kyverno-mutate-injetar-securitycontext)
    - [Etapa 4.3 — Kyverno: Generate (NetworkPolicy automática) + Registry confiável](#etapa-43--kyverno-generate-networkpolicy-automática--registry-confiável)
    - [Etapa 4.4 — RBAC: 4 perfis com certificados X.509](#etapa-44--rbac-4-perfis-com-certificados-x509)
    - [Etapa 4.5 — Helm Chart umbrella](#etapa-45--helm-chart-umbrella)


## Etapa 1.2 — Justificativa: Dockerfile multi-stage + runtime Distroless nonroot

---

### Por que Dockerfile multi-stage?

O build multi-stage divide o processo em dois estágios com responsabilidades distintas:

**Estágio 1 — builder (`python:3.11-slim-bookworm`)**

É a imagem "suja": tem `pip`, compiladores, build tools e todo o ferramental necessário para instalar as dependências Python. Neste estágio instalamos os pacotes com `pip install --target=/packages`, que coloca tudo num diretório isolado em vez de no ambiente global. Isso facilita copiar exatamente o que a aplicação precisa para o próximo estágio — sem carregar o pip, sem carregar o apt, sem carregar nenhuma ferramenta de build.

**Estágio 2 — runtime (`gcr.io/distroless/python3-debian12:nonroot`)**

Só recebe o que foi produzido no builder: os pacotes Python em `/packages` e o arquivo `main.py`. Não existe shell, não existe `apt`, não existe `pip`, não existe `curl`. A imagem final é a menor e mais restrita possível.

**O resultado prático**: a imagem de produção não carrega nada do que foi usado para construí-la. Vulnerabilidades que existam nas ferramentas de build (compiladores, pip, etc.) simplesmente não chegam à imagem final — elas ficam num estágio intermediário que é descartado pelo Docker ao final do build.

---

### Por que imagem Distroless (sem shell, sem package manager)?

Uma imagem tradicional baseada em Debian ou Alpine inclui centenas de utilitários que nunca são usados pela aplicação em produção: `bash`, `sh`, `curl`, `wget`, `apt`, `dpkg`, bibliotecas de sistema genéricas. Cada um desses pacotes é uma superfície de ataque potencial — uma vulnerabilidade CVE num utilitário que nem é usado pela aplicação pode comprometer o container.

A imagem Distroless (`gcr.io/distroless/python3-debian12`) remove tudo isso. Contém apenas:

- O interpretador Python e as bibliotecas `glibc` que ele precisa
- Os certificados TLS do sistema (`ca-certificates`)
- Nenhum shell (`/bin/sh` não existe)
- Nenhum gerenciador de pacotes
- Nenhum utilitário de rede, compressão ou texto

**Implicações de segurança diretas**:

| Vetor de ataque | Imagem tradicional | Distroless |
|---|---|---|
| Execução de shell após RCE | ✅ possível (`/bin/bash`) | ❌ impossível |
| Download de payload externo | ✅ possível (`curl`, `wget`) | ❌ impossível |
| Instalação de software no container | ✅ possível (`apt install`) | ❌ impossível |
| Escalada via ferramentas SUID | ✅ dependente dos pacotes | ❌ surface mínima |
| CVEs em utilitários não usados | ✅ frequente | ❌ inexistente |

Isso reduz drasticamente a quantidade de CVEs que o Trivy encontra — porque simplesmente não há pacotes para ter vulnerabilidade.

---

### Por que rodar como usuário não-root (UID 65532)?

Por padrão, containers rodam como `root` (UID 0). Isso significa que se um atacante explorar uma vulnerabilidade na aplicação e conseguir executar comandos no container, ele terá privilégios de root dentro do container. Em cenários com misconfigurações de namespace ou falhas no runtime de container, isso pode escalar para o host.

O usuário `nonroot` do Distroless tem UID **65532** — um valor alto deliberado para:

1. **Não colidir** com nenhum usuário de sistema do host (UIDs de sistema ficam abaixo de 1000)
2. **Não ter permissões** de escrita em nenhum diretório do sistema de arquivos da imagem
3. **Ser explicitamente declarado** na imagem, então o Kubernetes pode validar via `runAsNonRoot: true` e rejeitar o pod se a imagem tentar rodar como root

No contexto do TipsBank, as APIs só precisam escutar na porta 8080 (não-privilegiada — portas abaixo de 1024 exigem root no Linux) e acessar a rede. O UID 65532 tem exatamente essas capacidades — nada mais.

**Para a auditoria**, que escreve arquivos em `/data`, usamos um `initContainer` que roda como root para criar o diretório e ajustar o dono (`chown 65532:65532 /data`) antes do container principal subir. Assim o container de aplicação nunca precisa de root, mesmo precisando escrever em disco.

---

## Trivy — Scan de vulnerabilidades (Etapa 1.2)

> **Data do scan**: 2026-04-22  
> **Ferramenta**: Trivy (severidades HIGH e CRITICAL)  
> **Resultado final**: ✅ 0 vulnerabilidades HIGH/CRITICAL em todas as 4 imagens

---

### Vulnerabilidades encontradas e corrigidas

| Componente | CVE | Severidade | Pacote afetado | Correção aplicada |
|---|---|---|---|---|
| `api-contas`, `api-transacoes`, `auditoria` | CVE-2024-47874 | HIGH | `starlette` 0.38.6 | `fastapi>=0.115.4` → starlette resolvido para 1.0.0 |
| `web` | CVE-2025-15467, CVE-2025-49794, CVE-2025-49796 | CRITICAL | `openssl`, `libxml2` (Alpine 3.21.3) | `apk upgrade --no-cache` no Dockerfile |
| `web` | + 21 CVEs adicionais | HIGH | `musl`, `zlib`, `libpng`, `libexpat`, `libssl3` | `apk upgrade --no-cache` no Dockerfile |

**Decisões técnicas:**

- **APIs Python**: `fastapi==0.115.0` restringia `starlette<0.39.0`, bloqueando a correção do CVE-2024-47874. Solução: atualizar para `fastapi>=0.115.4` (aceita `starlette>=0.40.0`). Versão resolvida: fastapi 0.136.0 / starlette 1.0.0.
- **web**: A imagem base `nginxinc/nginx-unprivileged:1.27-alpine` trazia 24 CVEs em pacotes Alpine desatualizados. Solução: `RUN apk upgrade --no-cache` como root antes de restaurar `USER 101`, sem trocar a imagem base.

---

### Resultado final — `trivy image --severity HIGH,CRITICAL`

#### zenardi/tipsbank-api-contas:v1.0.0
```

Report Summary

┌──────────────────────────────────────────────────────┬────────────┬─────────────────┬─────────┐
│                        Target                        │    Type    │ Vulnerabilities │ Secrets │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ zenardi/tipsbank-api-contas:v1.0.0 (wolfi 20230201)  │   wolfi    │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/SQLAlchemy-2.0.35.dist-info/METADATA        │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/annotated_doc-0.0.4.dist-info/METADATA      │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/annotated_types-0.7.0.dist-info/METADATA    │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/anyio-4.13.0.dist-info/METADATA             │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/bcrypt-4.2.0.dist-info/METADATA             │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/click-8.3.3.dist-info/METADATA              │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/fastapi-0.136.0.dist-info/METADATA          │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/greenlet-3.4.0.dist-info/METADATA           │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/h11-0.16.0.dist-info/METADATA               │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/httptools-0.7.1.dist-info/METADATA          │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/idna-3.13.dist-info/METADATA                │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/prometheus_client-0.20.0.dist-info/METADATA │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/psycopg-3.2.13.dist-info/METADATA           │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/psycopg_binary-3.2.13.dist-info/METADATA    │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/pydantic-2.9.2.dist-info/METADATA           │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/pydantic_core-2.23.4.dist-info/METADATA     │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/python_dotenv-1.2.2.dist-info/METADATA      │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/pyyaml-6.0.3.dist-info/METADATA             │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/starlette-1.0.0.dist-info/METADATA          │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/typing_extensions-4.15.0.dist-info/METADATA │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/typing_inspection-0.4.2.dist-info/METADATA  │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/uvicorn-0.30.6.dist-info/METADATA           │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/uvloop-0.22.1.dist-info/METADATA            │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/watchfiles-1.1.1.dist-info/METADATA         │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/websockets-16.0.dist-info/METADATA          │ python-pkg │        0        │    -    │
└──────────────────────────────────────────────────────┴────────────┴─────────────────┴─────────┘
Legend:
- '-': Not scanned
- '0': Clean (no security findings detected)
```

#### zenardi/tipsbank-api-transacoes:v1.0.0
```

Report Summary

┌─────────────────────────────────────────────────────────┬────────────┬─────────────────┬─────────┐
│                         Target                          │    Type    │ Vulnerabilities │ Secrets │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ zenardi/tipsbank-api-transacoes:v1.0.0 (wolfi 20230201) │   wolfi    │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/SQLAlchemy-2.0.35.dist-info/METADATA           │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/annotated_doc-0.0.4.dist-info/METADATA         │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/annotated_types-0.7.0.dist-info/METADATA       │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/anyio-4.13.0.dist-info/METADATA                │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/certifi-2026.4.22.dist-info/METADATA           │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/click-8.3.3.dist-info/METADATA                 │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/fastapi-0.136.0.dist-info/METADATA             │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/greenlet-3.4.0.dist-info/METADATA              │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/h11-0.16.0.dist-info/METADATA                  │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/httpcore-1.0.9.dist-info/METADATA              │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/httptools-0.7.1.dist-info/METADATA             │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/httpx-0.27.2.dist-info/METADATA                │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/idna-3.13.dist-info/METADATA                   │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/prometheus_client-0.20.0.dist-info/METADATA    │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/psycopg-3.2.13.dist-info/METADATA              │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/psycopg_binary-3.2.13.dist-info/METADATA       │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/pydantic-2.9.2.dist-info/METADATA              │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/pydantic_core-2.23.4.dist-info/METADATA        │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/python_dotenv-1.2.2.dist-info/METADATA         │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/pyyaml-6.0.3.dist-info/METADATA                │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/sniffio-1.3.1.dist-info/METADATA               │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/starlette-1.0.0.dist-info/METADATA             │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/typing_extensions-4.15.0.dist-info/METADATA    │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/typing_inspection-0.4.2.dist-info/METADATA     │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/uvicorn-0.30.6.dist-info/METADATA              │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/uvloop-0.22.1.dist-info/METADATA               │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/watchfiles-1.1.1.dist-info/METADATA            │ python-pkg │        0        │    -    │
├─────────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/websockets-16.0.dist-info/METADATA             │ python-pkg │        0        │    -    │
└─────────────────────────────────────────────────────────┴────────────┴─────────────────┴─────────┘
Legend:
- '-': Not scanned
- '0': Clean (no security findings detected)
```

#### zenardi/tipsbank-auditoria:v1.0.0
```

Report Summary

┌──────────────────────────────────────────────────────┬────────────┬─────────────────┬─────────┐
│                        Target                        │    Type    │ Vulnerabilities │ Secrets │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ zenardi/tipsbank-auditoria:v1.0.0 (wolfi 20230201)   │   wolfi    │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/annotated_doc-0.0.4.dist-info/METADATA      │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/annotated_types-0.7.0.dist-info/METADATA    │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/anyio-4.13.0.dist-info/METADATA             │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/click-8.3.3.dist-info/METADATA              │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/fastapi-0.136.0.dist-info/METADATA          │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/h11-0.16.0.dist-info/METADATA               │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/httptools-0.7.1.dist-info/METADATA          │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/idna-3.13.dist-info/METADATA                │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/prometheus_client-0.20.0.dist-info/METADATA │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/pydantic-2.9.2.dist-info/METADATA           │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/pydantic_core-2.23.4.dist-info/METADATA     │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/python_dotenv-1.2.2.dist-info/METADATA      │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/pyyaml-6.0.3.dist-info/METADATA             │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/starlette-1.0.0.dist-info/METADATA          │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/typing_extensions-4.15.0.dist-info/METADATA │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/typing_inspection-0.4.2.dist-info/METADATA  │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/uvicorn-0.30.6.dist-info/METADATA           │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/uvloop-0.22.1.dist-info/METADATA            │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/watchfiles-1.1.1.dist-info/METADATA         │ python-pkg │        0        │    -    │
├──────────────────────────────────────────────────────┼────────────┼─────────────────┼─────────┤
│ packages/websockets-16.0.dist-info/METADATA          │ python-pkg │        0        │    -    │
└──────────────────────────────────────────────────────┴────────────┴─────────────────┴─────────┘
Legend:
- '-': Not scanned
- '0': Clean (no security findings detected)
```

#### zenardi/tipsbank-web:v1.0.0
```
Report Summary

┌─────────────────────────────────────────────┬────────┬─────────────────┬─────────┐
│                   Target                    │  Type  │ Vulnerabilities │ Secrets │
├─────────────────────────────────────────────┼────────┼─────────────────┼─────────┤
│ zenardi/tipsbank-web:v1.0.0 (alpine 3.21.3) │ alpine │        0        │    -    │
└─────────────────────────────────────────────┴────────┴─────────────────┴─────────┘
Legend:
- '-': Not scanned
- '0': Clean (no security findings detected)
```


---

## Docker Scout — Scan de vulnerabilidades (Etapa 1.2)

> **Data do scan**: 2026-04-22  
> **Ferramenta**: Docker Scout CVEs (todas as severidades)  
> **Resultado final**: ✅ 0 HIGH/CRITICAL em todas as imagens | 1 MEDIUM unfixable aceito em `web`

---

### Vulnerabilidades encontradas e corrigidas

| Componente | CVE | Severidade | Pacote | Fix disponível | Correção aplicada |
|---|---|---|---|---|---|
| `web` | CVE-2026-3805 | HIGH | `curl 8.14.1-r2` | Não | `apk del curl` — não é dep do nginx |
| `web` | CVE-2026-27135 | HIGH | `nghttp2-libs 1.64.0-r0` | Não | Removido como dep transitiva do curl |
| `web` | CVE-2025-48175 | MEDIUM | `libavif 1.0.4-r0` | Não | `apk del nginx-module-image-filter` → cascata remove libgd+libavif |
| `web` | CVE-2025-48174 | MEDIUM | `libavif 1.0.4-r0` | Não | Idem acima |
| `web` | CVE-2026-34085 | MEDIUM | `fontconfig 2.15.0-r1` | Não | Idem acima (dep transitiva de libgd) |
| `web` | CVE-2025-60876 | MEDIUM | `busybox 1.37.0-r14` | Não | ⚠️ **Risco aceito** — core Alpine, não removível |

**Decisões técnicas:**
- `curl` não é usado pelo nginx (`apk info --rdepends curl` vazio) → removido com `apk del curl`. Remoção cascateia `libcurl` e `nghttp2-libs`.
- `nginx-module-image-filter` não é usado pelo TipsBank (proxy reverso puro) → removido. Remoção cascateia `libgd`, `libavif` e `fontconfig`.
- `busybox` é o shell core do Alpine (`/bin/sh`). Sem fix disponível, sem alternativa de remoção. CVE MEDIUM, aceito como risco residual.
- A imagem passou de **75 → 39 pacotes** após as remoções.

---

### Resultado final — `docker scout cves zenardi/tipsbank-<app>:v1.0.0`

#### zenardi/tipsbank-api-contas:v1.0.0
```
Target            │  zenardi/tipsbank-api-contas:v1.0.0
  digest          │  ec3660cf72b1
  vulnerabilities │    0C     0H     0M     0L
  packages        │ 79

No vulnerable packages detected
```

#### zenardi/tipsbank-api-transacoes:v1.0.0
```
Target            │  zenardi/tipsbank-api-transacoes:v1.0.0
  digest          │  de5b05137260
  vulnerabilities │    0C     0H     0M     0L
  packages        │ 82

No vulnerable packages detected
```

#### zenardi/tipsbank-auditoria:v1.0.0
```
Target            │  zenardi/tipsbank-auditoria:v1.0.0
  digest          │  14fd7cbe513d
  vulnerabilities │    0C     0H     0M     0L
  packages        │ 74

No vulnerable packages detected
```

#### zenardi/tipsbank-web:v1.0.0
```
    ✓ Image stored for indexing
    ✓ Indexed 39 packages
    ✓ Provenance obtained from attestation
    ✗ Detected 1 vulnerable package with 1 vulnerability


## Overview

                   │                   Analyzed Image
───────────────────┼─────────────────────────────────────────────────────
 Target            │  zenardi/tipsbank-web:v1.0.0
   digest          │  eb8c1376f4e7
   platform        │ linux/amd64
   provenance      │ git@github.com:Zenardi/DescomplicandoKubernetes.git
                   │  bb1a048f5f0dbb6f37aaa7d34b4d55135572d5ec
   vulnerabilities │    0C     0H     1M     0L
   size            │ 26 MB
   packages        │ 39


## Packages and Vulnerabilities

   0C     0H     1M     0L  busybox 1.37.0-r14
pkg:apk/alpine/busybox@1.37.0-r14?os_name=alpine&os_version=3.21

    ✗ MEDIUM CVE-2025-60876
      https://scout.docker.com/v/CVE-2025-60876
      Affected range : <=1.37.0-r14
      Fixed version  : not fixed



1 vulnerability found in 1 package
  CRITICAL  0
  HIGH      0
  MEDIUM    1
  LOW       0
```

---

## Etapa 1.6 — PV NFS (RWX) e Locking de Arquivo Concorrente

### Configuração do NFS

| Item | Valor |
|---|---|
| Servidor NFS | worker1 — 192.168.56.11 |
| Export path | `/srv/nfs/auditoria` |
| Opções de export | `rw,sync,no_subtree_check,no_root_squash` |
| NFS versão (mount) | NFSv4.1 (`nfsvers=4.1`) |
| Mount options | `hard,timeo=600,retrans=3` |
| PV | `auditoria-nfs-pv` — 5Gi, RWX, Retain |
| PVC | `auditoria-nfs-pvc` (tipsbank-auditoria) — Bound |

### Teste de escrita concorrente

Após escalar a auditoria para **3 réplicas** (2 no worker2, 1 no worker1), foram disparadas
100 transferências via api-transacoes. Cada transferência gera 1 evento de auditoria
(`POST /eventos`), escrito com `open("a")` no arquivo diário `/data/eventos-YYYY-MM-DD.jsonl`.

| Pod | Node | Eventos lidos via `GET /eventos?limit=500` |
|---|---|---|
| auditoria-74dc9885c-n2jkx | worker2 | 201 |
| auditoria-74dc9885c-nzfvv | worker2 | 201 |
| auditoria-74dc9885c-z8mfc | worker1 | 201 |

> Os 201 eventos incluem testes das etapas anteriores + 100 da etapa 1.6.

### Análise de locking NFS

**Comportamento observado:** nenhuma linha corrompida ou duplicada detectada.
Os 3 pods leram exatamente o mesmo número de eventos do arquivo compartilhado.

**Por que funciona:** NFSv4.1 inclui suporte nativo a *byte-range locking* (RFC 5661).
A operação `open("a")` do Python abre o arquivo em modo append; o kernel Linux combina
o `O_APPEND` com o lock POSIX implícito do NFSv4.1, garantindo que cada write seja
atômico do ponto de vista do arquivo — cada réplica escreve uma linha JSONL completa
sem entrelaçamento com outras réplicas.

**Opção `no_root_squash`:** necessária para que o processo `nonroot` (UID 65532 / Chainguard)
possa criar e escrever no diretório exportado. O diretório `/srv/nfs/auditoria` no servidor
foi pré-criado com `chown 65532:65532` para garantir permissão mesmo sem root.

**Conclusão:** não foram observados conflitos de escrita. O NFS com `hard` mount e NFSv4.1
é adequado para a carga de append sequencial deste serviço de auditoria.

---

## Etapa 3.6 — PrometheusRule com Alertas de SLO

> **Data**: _<YYYY-MM-DD>_
> **Ferramenta**: kube-prometheus-stack (Prometheus Operator + Alertmanager)
> **Manifesto**: `k8s/semana3/25-prometheusrule.yaml`
> **Namespace**: `tipsbank-monitoring`
> **Resultado**: _<resumo: ex. "4 alertas carregados, 3 disparados em teste controlado">_

---

### Alertas configurados

| # | Alerta | Severidade | Trigger | Janela (`for`) |
|---|---|---|---|---|
| 1 | `TipsBankApiDown` | critical | `up{job=~"..."} == 0` | 2m |
| 2 | `TipsBankP99Alto` | warning | P99 de `http_request_duration_seconds` > 500ms | 5m |
| 3 | `TipsBankErroAltoApi` | critical | Taxa de erros 5xx > 5% | 3m |
| 4 | `TipsBankPodCrashLoop` | warning | >3 restarts em 10 minutos | 5m |

---

### Validação — PrometheusRule carregada pelo Prometheus Operator

```bash
# 1. Objeto criado e reconhecido pelo operator
kubectl get prometheusrule -n tipsbank-monitoring tipsbank-slo-alerts
```

```
NAME                  AGE
tipsbank-slo-alerts   3h18m
```

```bash
# 2. Regras visíveis na API do Prometheus
kubectl -n tipsbank-monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[] | select(.name=="tipsbank.slo")'
```

```json
{
  "name": "tipsbank.slo",
  "file": "/etc/prometheus/rules/prometheus-kube-prometheus-stack-prometheus-rulefiles-0/tipsbank-monitoring-tipsbank-slo-alerts-19544a96-9e45-456b-b1aa-9eb5a9a00d2e.yaml",
  "rules": [
    {
      "state": "inactive",
      "name": "TipsBankApiDown",
      "query": "up{job=~\"tipsbank-contas/api-contas|tipsbank-transacoes/api-transacoes|tipsbank-auditoria/auditoria\"} == 0",
      "duration": 120,
      "keepFiringFor": 0,
      "labels": {
        "severity": "critical"
      },
      "annotations": {
        "description": "Target {{ $labels.instance }} sem resposta há mais de 2 minutos.",
        "summary": "API {{ $labels.job }} está down"
      },
      "alerts": [],
      "health": "ok",
      "evaluationTime": 0.000241679,
      "lastEvaluation": "2026-05-14T23:58:33.919072703Z",
      "type": "alerting"
    },
    {
      "state": "inactive",
      "name": "TipsBankP99Alto",
      "query": "histogram_quantile(0.99, sum by (job, le) (rate(http_request_duration_seconds_bucket{namespace=~\"tipsbank-.*\"}[5m]))) > 0.5",
      "duration": 300,
      "keepFiringFor": 0,
      "labels": {
        "severity": "warning"
      },
      "annotations": {
        "description": "P99 atual = {{ $value | humanizeDuration }}",
        "summary": "P99 de latência acima de 500ms em {{ $labels.job }}"
      },
      "alerts": [],
      "health": "ok",
      "evaluationTime": 0.000177022,
      "lastEvaluation": "2026-05-14T23:58:33.919323893Z",
      "type": "alerting"
    },
    {
      "state": "inactive",
      "name": "TipsBankErroAltoApi",
      "query": "(sum by (job) (rate(http_requests_total{namespace=~\"tipsbank-.*\",status=~\"5..\"}[3m])) / sum by (job) (rate(http_requests_total{namespace=~\"tipsbank-.*\"}[3m]))) > 0.05",
      "duration": 180,
      "keepFiringFor": 0,
      "labels": {
        "severity": "critical"
      },
      "annotations": {
        "description": "Taxa atual: {{ $value | humanizePercentage }}",
        "summary": "Taxa de erros 5xx > 5% em {{ $labels.job }}"
      },
      "alerts": [],
      "health": "ok",
      "evaluationTime": 0.000147981,
      "lastEvaluation": "2026-05-14T23:58:33.919505298Z",
      "type": "alerting"
    },
    {
      "state": "inactive",
      "name": "TipsBankPodCrashLoop",
      "query": "increase(kube_pod_container_status_restarts_total{namespace=~\"tipsbank-.*\"}[10m]) > 3",
      "duration": 300,
      "keepFiringFor": 0,
      "labels": {
        "severity": "warning"
      },
      "annotations": {
        "description": "{{ $value }} restarts nos últimos 10 minutos no namespace {{ $labels.namespace }}.",
        "summary": "Pod {{ $labels.pod }} em CrashLoop"
      },
      "alerts": [],
      "health": "ok",
      "evaluationTime": 0.000304544,
      "lastEvaluation": "2026-05-14T23:58:33.919658071Z",
      "type": "alerting"
    }
  ],
  "interval": 30,
  "limit": 0,
  "evaluationTime": 0.000921205,
  "lastEvaluation": "2026-05-14T23:58:33.919045151Z"
}
```

---

### Teste de disparo dos alertas

#### 1. `TipsBankApiDown`

**Como reproduzir:** escalar uma das APIs para 0 réplicas e aguardar 2 minutos.

```bash
kubectl scale -n tipsbank-contas deploy/api-contas --replicas=0
# aguardar 2m, depois verificar
curl -ks https://prometheus.tipsbank.local:8443/api/v1/alerts | jq '.data.alerts'
```

**Evidência (alerta em estado FIRING):**

```
[
  {
    "labels": {
      "alertname": "TargetDown",
      "job": "kube-controller-manager",
      "namespace": "kube-system",
      "service": "kube-prometheus-stack-kube-controller-manager",
      "severity": "warning"
    },
    "annotations": {
      "description": "100% of the kube-controller-manager/kube-prometheus-stack-kube-controller-manager targets in kube-system namespace are down.",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/general/targetdown",
      "summary": "One or more targets are unreachable."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:39:36.139252406Z",
    "value": "1e+02"
  },
  {
    "labels": {
      "alertname": "TargetDown",
      "job": "kube-scheduler",
      "namespace": "kube-system",
      "service": "kube-prometheus-stack-kube-scheduler",
      "severity": "warning"
    },
    "annotations": {
      "description": "100% of the kube-scheduler/kube-prometheus-stack-kube-scheduler targets in kube-system namespace are down.",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/general/targetdown",
      "summary": "One or more targets are unreachable."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:39:36.139252406Z",
    "value": "1e+02"
  },
  {
    "labels": {
      "alertname": "TargetDown",
      "job": "api-transacoes",
      "namespace": "tipsbank-transacoes",
      "service": "api-transacoes",
      "severity": "warning"
    },
    "annotations": {
      "description": "100% of the api-transacoes/api-transacoes targets in tipsbank-transacoes namespace are down.",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/general/targetdown",
      "summary": "One or more targets are unreachable."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:40:36.139252406Z",
    "value": "1e+02"
  },
  {
    "labels": {
      "alertname": "TargetDown",
      "job": "auditoria",
      "namespace": "tipsbank-auditoria",
      "service": "auditoria",
      "severity": "warning"
    },
    "annotations": {
      "description": "100% of the auditoria/auditoria targets in tipsbank-auditoria namespace are down.",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/general/targetdown",
      "summary": "One or more targets are unreachable."
    },
    "state": "firing",
    "activeAt": "2026-05-14T21:27:06.139252406Z",
    "value": "1e+02"
  },
  {
    "labels": {
      "alertname": "TargetDown",
      "job": "kube-etcd",
      "namespace": "kube-system",
      "service": "kube-prometheus-stack-kube-etcd",
      "severity": "warning"
    },
    "annotations": {
      "description": "100% of the kube-etcd/kube-prometheus-stack-kube-etcd targets in kube-system namespace are down.",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/general/targetdown",
      "summary": "One or more targets are unreachable."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:39:06.139252406Z",
    "value": "1e+02"
  },
  {
    "labels": {
      "alertname": "TargetDown",
      "job": "kube-proxy",
      "namespace": "kube-system",
      "service": "kube-prometheus-stack-kube-proxy",
      "severity": "warning"
    },
    "annotations": {
      "description": "100% of the kube-proxy/kube-prometheus-stack-kube-proxy targets in kube-system namespace are down.",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/general/targetdown",
      "summary": "One or more targets are unreachable."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:39:06.139252406Z",
    "value": "1e+02"
  },
  {
    "labels": {
      "alertname": "Watchdog",
      "severity": "none"
    },
    "annotations": {
      "description": "This is an alert meant to ensure that the entire alerting pipeline is functional.\nThis alert is always firing, therefore it should always be firing in Alertmanager\nand always fire against a receiver. There are integrations with various notification\nmechanisms that send a notification when this alert is not firing. For example the\n\"DeadMansSnitch\" integration in PagerDuty.\n",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/general/watchdog",
      "summary": "An alert that should always be firing to certify that Alertmanager is working properly."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:39:06.139252406Z",
    "value": "1e+00"
  },
  {
    "labels": {
      "alertname": "etcdMembersDown",
      "container": "etcd",
      "job": "kube-etcd",
      "namespace": "kube-system",
      "service": "kube-prometheus-stack-kube-etcd",
      "severity": "warning"
    },
    "annotations": {
      "description": "etcd cluster \"kube-etcd\": members are down (1).",
      "summary": "etcd cluster members are down."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:39:22.187294644Z",
    "value": "1e+00"
  },
  {
    "labels": {
      "alertname": "etcdInsufficientMembers",
      "container": "etcd",
      "endpoint": "http-metrics",
      "job": "kube-etcd",
      "namespace": "kube-system",
      "service": "kube-prometheus-stack-kube-etcd",
      "severity": "critical"
    },
    "annotations": {
      "description": "etcd cluster \"kube-etcd\": insufficient members (0).",
      "summary": "etcd cluster has insufficient number of members."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:39:22.187294644Z",
    "value": "0e+00"
  },
  {
    "labels": {
      "alertname": "NodeClockNotSynchronising",
      "container": "node-exporter",
      "endpoint": "http-metrics",
      "instance": "172.18.0.7:9100",
      "job": "node-exporter",
      "namespace": "tipsbank-monitoring",
      "pod": "kube-prometheus-stack-prometheus-node-exporter-8chst",
      "service": "kube-prometheus-stack-prometheus-node-exporter",
      "severity": "warning"
    },
    "annotations": {
      "description": "Clock at 172.18.0.7:9100 is not synchronising. Ensure NTP is configured on this host.",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/node/nodeclocknotsynchronising",
      "summary": "Clock not synchronising."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:38:59.108451942Z",
    "value": "0e+00"
  },
  {
    "labels": {
      "alertname": "NodeClockNotSynchronising",
      "container": "node-exporter",
      "endpoint": "http-metrics",
      "instance": "172.18.0.6:9100",
      "job": "node-exporter",
      "namespace": "tipsbank-monitoring",
      "pod": "kube-prometheus-stack-prometheus-node-exporter-hkwp2",
      "service": "kube-prometheus-stack-prometheus-node-exporter",
      "severity": "warning"
    },
    "annotations": {
      "description": "Clock at 172.18.0.6:9100 is not synchronising. Ensure NTP is configured on this host.",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/node/nodeclocknotsynchronising",
      "summary": "Clock not synchronising."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:39:29.108451942Z",
    "value": "0e+00"
  },
  {
    "labels": {
      "alertname": "NodeClockNotSynchronising",
      "container": "node-exporter",
      "endpoint": "http-metrics",
      "instance": "172.18.0.8:9100",
      "job": "node-exporter",
      "namespace": "tipsbank-monitoring",
      "pod": "kube-prometheus-stack-prometheus-node-exporter-kpfz6",
      "service": "kube-prometheus-stack-prometheus-node-exporter",
      "severity": "warning"
    },
    "annotations": {
      "description": "Clock at 172.18.0.8:9100 is not synchronising. Ensure NTP is configured on this host.",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/node/nodeclocknotsynchronising",
      "summary": "Clock not synchronising."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:39:29.108451942Z",
    "value": "0e+00"
  },
  {
    "labels": {
      "alertname": "NodeClockNotSynchronising",
      "container": "node-exporter",
      "endpoint": "http-metrics",
      "instance": "172.18.0.9:9100",
      "job": "node-exporter",
      "namespace": "tipsbank-monitoring",
      "pod": "kube-prometheus-stack-prometheus-node-exporter-6tvsc",
      "service": "kube-prometheus-stack-prometheus-node-exporter",
      "severity": "warning"
    },
    "annotations": {
      "description": "Clock at 172.18.0.9:9100 is not synchronising. Ensure NTP is configured on this host.",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/node/nodeclocknotsynchronising",
      "summary": "Clock not synchronising."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:38:59.108451942Z",
    "value": "0e+00"
  },
  {
    "labels": {
      "alertname": "CPUThrottlingHigh",
      "container": "collector",
      "instance": "172.18.0.9:10250",
      "namespace": "tipsbank-monitoring",
      "pod": "node-collector-pqxdd",
      "service": "kube-prometheus-stack-kubelet",
      "severity": "info"
    },
    "annotations": {
      "description": "55.56% throttling of CPU in namespace tipsbank-monitoring for container collector in pod node-collector-pqxdd on cluster .",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/kubernetes/cputhrottlinghigh",
      "summary": "Processes experience elevated CPU throttling."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:42:38.373227266Z",
    "value": "5.555555555555555e-01"
  },
  {
    "labels": {
      "alertname": "CPUThrottlingHigh",
      "container": "collector",
      "instance": "172.18.0.7:10250",
      "namespace": "tipsbank-monitoring",
      "pod": "node-collector-n5b2w",
      "service": "kube-prometheus-stack-kubelet",
      "severity": "info"
    },
    "annotations": {
      "description": "55.17% throttling of CPU in namespace tipsbank-monitoring for container collector in pod node-collector-n5b2w on cluster .",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/kubernetes/cputhrottlinghigh",
      "summary": "Processes experience elevated CPU throttling."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:42:38.373227266Z",
    "value": "5.517241379310345e-01"
  },
  {
    "labels": {
      "alertname": "CPUThrottlingHigh",
      "container": "collector",
      "instance": "172.18.0.6:10250",
      "namespace": "tipsbank-monitoring",
      "pod": "node-collector-4xmpv",
      "service": "kube-prometheus-stack-kubelet",
      "severity": "info"
    },
    "annotations": {
      "description": "65.62% throttling of CPU in namespace tipsbank-monitoring for container collector in pod node-collector-4xmpv on cluster .",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/kubernetes/cputhrottlinghigh",
      "summary": "Processes experience elevated CPU throttling."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:42:38.373227266Z",
    "value": "6.5625e-01"
  },
  {
    "labels": {
      "alertname": "CPUThrottlingHigh",
      "container": "collector",
      "instance": "172.18.0.8:10250",
      "namespace": "tipsbank-monitoring",
      "pod": "node-collector-psqlp",
      "service": "kube-prometheus-stack-kubelet",
      "severity": "info"
    },
    "annotations": {
      "description": "65.45% throttling of CPU in namespace tipsbank-monitoring for container collector in pod node-collector-psqlp on cluster .",
      "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/kubernetes/cputhrottlinghigh",
      "summary": "Processes experience elevated CPU throttling."
    },
    "state": "firing",
    "activeAt": "2026-05-14T20:42:38.373227266Z",
    "value": "6.545454545454545e-01"
  }
]
```

---

#### 2. `TipsBankP99Alto`

![](./prints-evidencias/semana3/09-grafana-locust.png)

---

### Alertas recebidos pelo Alertmanager

```bash
kubectl -n tipsbank-monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 & curl -ks http://localhost:9093/api/v2/alerts | jq '.[] | {labels: .labels, status: .status.state, startsAt: .startsAt}'
```

```
{
  "labels": {
    "alertname": "TargetDown",
    "job": "kube-etcd",
    "namespace": "kube-system",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-kube-etcd",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:49:06.139Z"
}
{
  "labels": {
    "alertname": "TargetDown",
    "job": "kube-proxy",
    "namespace": "kube-system",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-kube-proxy",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:49:06.139Z"
}
{
  "labels": {
    "alertname": "NodeClockNotSynchronising",
    "container": "node-exporter",
    "endpoint": "http-metrics",
    "instance": "172.18.0.8:9100",
    "job": "node-exporter",
    "namespace": "tipsbank-monitoring",
    "pod": "kube-prometheus-stack-prometheus-node-exporter-kpfz6",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-prometheus-node-exporter",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:49:29.108Z"
}
{
  "labels": {
    "alertname": "NodeClockNotSynchronising",
    "container": "node-exporter",
    "endpoint": "http-metrics",
    "instance": "172.18.0.9:9100",
    "job": "node-exporter",
    "namespace": "tipsbank-monitoring",
    "pod": "kube-prometheus-stack-prometheus-node-exporter-6tvsc",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-prometheus-node-exporter",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:48:59.108Z"
}
{
  "labels": {
    "alertname": "Watchdog",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "severity": "none"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:39:06.139Z"
}
{
  "labels": {
    "alertname": "NodeClockNotSynchronising",
    "container": "node-exporter",
    "endpoint": "http-metrics",
    "instance": "172.18.0.6:9100",
    "job": "node-exporter",
    "namespace": "tipsbank-monitoring",
    "pod": "kube-prometheus-stack-prometheus-node-exporter-hkwp2",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-prometheus-node-exporter",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:49:29.108Z"
}
{
  "labels": {
    "alertname": "CPUThrottlingHigh",
    "container": "collector",
    "instance": "172.18.0.7:10250",
    "namespace": "tipsbank-monitoring",
    "pod": "node-collector-n5b2w",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-kubelet",
    "severity": "info"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:57:38.373Z"
}
{
  "labels": {
    "alertname": "TargetDown",
    "job": "kube-scheduler",
    "namespace": "kube-system",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-kube-scheduler",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:49:36.139Z"
}
{
  "labels": {
    "alertname": "NodeClockNotSynchronising",
    "container": "node-exporter",
    "endpoint": "http-metrics",
    "instance": "172.18.0.7:9100",
    "job": "node-exporter",
    "namespace": "tipsbank-monitoring",
    "pod": "kube-prometheus-stack-prometheus-node-exporter-8chst",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-prometheus-node-exporter",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:48:59.108Z"
}
{
  "labels": {
    "alertname": "etcdInsufficientMembers",
    "container": "etcd",
    "endpoint": "http-metrics",
    "job": "kube-etcd",
    "namespace": "kube-system",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-kube-etcd",
    "severity": "critical"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:42:22.187Z"
}
{
  "labels": {
    "alertname": "etcdMembersDown",
    "container": "etcd",
    "job": "kube-etcd",
    "namespace": "kube-system",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-kube-etcd",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:59:22.187Z"
}
{
  "labels": {
    "alertname": "CPUThrottlingHigh",
    "container": "collector",
    "instance": "172.18.0.6:10250",
    "namespace": "tipsbank-monitoring",
    "pod": "node-collector-4xmpv",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-kubelet",
    "severity": "info"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:57:38.373Z"
}
{
  "labels": {
    "alertname": "TargetDown",
    "job": "kube-controller-manager",
    "namespace": "kube-system",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-kube-controller-manager",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:49:36.139Z"
}
{
  "labels": {
    "alertname": "TargetDown",
    "job": "auditoria",
    "namespace": "tipsbank-auditoria",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "auditoria",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T21:37:06.139Z"
}
{
  "labels": {
    "alertname": "CPUThrottlingHigh",
    "container": "collector",
    "instance": "172.18.0.8:10250",
    "namespace": "tipsbank-monitoring",
    "pod": "node-collector-psqlp",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-kubelet",
    "severity": "info"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:57:38.373Z"
}
{
  "labels": {
    "alertname": "TargetDown",
    "job": "api-contas",
    "namespace": "tipsbank-contas",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "api-contas",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-15T00:18:06.139Z"
}
{
  "labels": {
    "alertname": "TargetDown",
    "job": "api-transacoes",
    "namespace": "tipsbank-transacoes",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "api-transacoes",
    "severity": "warning"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:50:36.139Z"
}
{
  "labels": {
    "alertname": "CPUThrottlingHigh",
    "container": "collector",
    "instance": "172.18.0.9:10250",
    "namespace": "tipsbank-monitoring",
    "pod": "node-collector-pqxdd",
    "prometheus": "tipsbank-monitoring/kube-prometheus-stack-prometheus",
    "service": "kube-prometheus-stack-kubelet",
    "severity": "info"
  },
  "status": "active",
  "startsAt": "2026-05-14T20:57:38.373Z"
}
```

## Semana 4

### Etapa 4.1 — Kyverno: Validate (proibir root, proibir latest)

![kyverno-validate](./prints-evidencias/semana4/4.1-kyverno-validate.png)


### Etapa 4.2 — Kyverno: Mutate (injetar securityContext)

![pod-mutate](./prints-evidencias/semana4/4.2-pod-mutate.png)


![pod-inject](./prints-evidencias/semana4/4.2-inject.png)

### Etapa 4.3 — Kyverno: Generate (NetworkPolicy automática) + Registry confiável

![generate](./prints-evidencias/semana4/4.3-generate.png)

### Etapa 4.4 — RBAC: 4 perfis com certificados X.509

```sh
#########################################################
############### operador-contas #########################
#########################################################
❯ kubectl --kubeconfig=$KC/operador-contas.kubeconfig get pods -n tipsbank-contas
NAME                       READY   STATUS    RESTARTS   AGE
api-contas-97ffdcb-5qkmb   1/1     Running   0          66m
api-contas-97ffdcb-7vfsh   1/1     Running   0          66m
postgres-0                 1/1     Running   0          66m
postgres-replica-0         1/1     Running   0          66m

❯ kubectl --kubeconfig=$KC/operador-contas.kubeconfig get pods -n tipsbank-transacoes
Error from server (Forbidden): pods is forbidden: User "operador-contas" cannot list resource "pods" in API group "" in the namespace "tipsbank-transacoes"

#########################################################
############### auditor-global ##########################
#########################################################
❯ kubectl --kubeconfig=$KC/auditor-global.kubeconfig get pods -A
NAMESPACE             NAME                                                        READY   STATUS    RESTARTS   AGE
cert-manager          cert-manager-5957746d66-vqjbl                               1/1     Running   0          70m
cert-manager          cert-manager-cainjector-567c6b47ff-tdf9b                    1/1     Running   0          70m
cert-manager          cert-manager-webhook-7cc5c588cb-dklwt                       1/1     Running   0          70m
ingress-nginx         ingress-nginx-controller-56dc4b4c6-7kmk4                    1/1     Running   0          73m
kube-system           coredns-7d764666f9-764w9                                    1/1     Running   0          74m
kube-system           coredns-7d764666f9-rjzp4                                    1/1     Running   0          74m
kube-system           etcd-tipsbank-control-plane                                 1/1     Running   0          74m
kube-system           kindnet-j5qdb                                               1/1     Running   0          74m
kube-system           kindnet-nhg2v                                               1/1     Running   0          74m
kube-system           kindnet-x24tz                                               1/1     Running   0          74m
kube-system           kindnet-x4csv                                               1/1     Running   0          74m
kube-system           kube-apiserver-tipsbank-control-plane                       1/1     Running   0          74m
kube-system           kube-controller-manager-tipsbank-control-plane              1/1     Running   0          74m
kube-system           kube-proxy-crpqc                                            1/1     Running   0          74m
kube-system           kube-proxy-dmqtl                                            1/1     Running   0          74m
kube-system           kube-proxy-g6764                                            1/1     Running   0          74m
kube-system           kube-proxy-xnjdw                                            1/1     Running   0          74m
kube-system           kube-scheduler-tipsbank-control-plane                       1/1     Running   0          74m
kube-system           metrics-server-6795649cdf-wp6bd                             1/1     Running   0          65m
kyverno               kyverno-admission-controller-66756fbfdf-hvqph               1/1     Running   0          59m
kyverno               kyverno-background-controller-57f7cb7c48-drvpc              1/1     Running   0          59m
kyverno               kyverno-cleanup-controller-75c566db9c-x8db4                 1/1     Running   0          59m
kyverno               kyverno-reports-controller-dfdd969cd-mkjgc                  1/1     Running   0          59m
local-path-storage    local-path-provisioner-67b8995b4b-4rsn5                     1/1     Running   0          74m
tipsbank-auditoria    auditoria-67dc9bbddc-5rk9c                                  1/1     Running   0          65m
tipsbank-auditoria    auditoria-67dc9bbddc-jpjh8                                  1/1     Running   0          68m
tipsbank-contas       api-contas-97ffdcb-5qkmb                                    1/1     Running   0          68m
tipsbank-contas       api-contas-97ffdcb-7vfsh                                    1/1     Running   0          68m
tipsbank-contas       postgres-0                                                  1/1     Running   0          68m
tipsbank-contas       postgres-replica-0                                          1/1     Running   0          68m
tipsbank-monitoring   alertmanager-kube-prometheus-stack-alertmanager-0           2/2     Running   0          66m
tipsbank-monitoring   kube-prometheus-stack-grafana-d487bb469-r44zw               3/3     Running   0          66m
tipsbank-monitoring   kube-prometheus-stack-kube-state-metrics-58f5d9c5d4-gkghz   1/1     Running   0          66m
tipsbank-monitoring   kube-prometheus-stack-operator-6d54798576-fr2kj             1/1     Running   0          66m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter-8vc4s        1/1     Running   0          66m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter-pfhl5        1/1     Running   0          66m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter-pnb9c        1/1     Running   0          66m
tipsbank-monitoring   kube-prometheus-stack-prometheus-node-exporter-zq7xj        1/1     Running   0          66m
tipsbank-monitoring   locust-6978cd4b86-td85b                                     1/1     Running   0          65m
tipsbank-monitoring   node-collector-2b9fr                                        1/1     Running   0          65m
tipsbank-monitoring   node-collector-bwgmb                                        1/1     Running   0          65m
tipsbank-monitoring   node-collector-c2ld8                                        1/1     Running   0          65m
tipsbank-monitoring   node-collector-dj97f                                        1/1     Running   0          65m
tipsbank-monitoring   prometheus-kube-prometheus-stack-prometheus-0               2/2     Running   0          66m
tipsbank-transacoes   api-transacoes-cb94856d8-8ldpd                              2/2     Running   0          68m
tipsbank-transacoes   api-transacoes-cb94856d8-dfp4d                              2/2     Running   0          65m
tipsbank-transacoes   api-transacoes-cb94856d8-zxx87                              2/2     Running   0          68m
tipsbank-transacoes   api-transacoes-v2-5865bbfd54-n8nst                          2/2     Running   0          67m
tipsbank-web          web-7d656cf447-k6z9j                                        1/1     Running   0          68m
tipsbank-web          web-7d656cf447-mbnjk                                        1/1     Running   0          68m

❯ kubectl --kubeconfig=$KC/auditor-global.kubeconfig delete pod -n tipsbank-contas $(kubectl get pod -n tipsbank-contas -l app=api-contas -o name | head -1)
error: there is no need to specify a resource type as a separate argument when passing arguments in resource/name form (e.g. 'kubectl get resource/<resource_name>' instead of 'kubectl get resource resource/<resource_name>'



#########################################################
############### sre #####################################
#########################################################
❯ kubectl --kubeconfig=$KC/sre.kubeconfig get nodes
NAME                     STATUS   ROLES           AGE   VERSION
tipsbank-control-plane   Ready    control-plane   76m   v1.35.0
tipsbank-worker          Ready    <none>          76m   v1.35.0
tipsbank-worker2         Ready    <none>          76m   v1.35.0
tipsbank-worker3         Ready    <none>          76m   v1.35.0


#########################################################
############### TOKEN SA ################################
#########################################################
❯ kubectl get secret monitoring-reader-token -n tipsbank-monitoring -o jsonpath='{.data.token}' | base64 -d
eyJhbGciOiJSUzI1NiIsImtpZCI6IkZhRDlZYXhnUHBISElSMkVacm5BN2xHWVVwRnk1VzN0TFVQdlBpVGNyUG8ifQ.eyJpc3MiOiJrdWJlcm5ldGVzL3NlcnZpY2VhY2NvdW50Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9uYW1lc3BhY2UiOiJ0aXBzYmFuay1tb25pdG9yaW5nIiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZWNyZXQubmFtZSI6Im1vbml0b3JpbmctcmVhZGVyLXRva2VuIiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZXJ2aWNlLWFjY291bnQubmFtZSI6Im1vbml0b3JpbmctcmVhZGVyLXNhIiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZXJ2aWNlLWFjY291bnQudWlkIjoiMGY2MmQxZDctMjc5My00ZDUxLTlhYWEtMTIxOTdlNTc3OWUzIiwic3ViIjoic3lzdGVtOnNlcnZpY2VhY2NvdW50OnRpcHNiYW5rLW1vbml0b3Jpbmc6bW9uaXRvcmluZy1yZWFkZXItc2EifQ.hG22KKy9GS5LlKy2Yt5it-tMN6Y_73UDmER-Gh4mxiGmzRla-CnFhNu9Lnp7t8gvZ6ZYcrTvvqJPynEHlYjfgzVwKpE5KG5jR3FWyb50aNSr5x74Vaxlq--sdXXlTaAvfyouaSOi2vPYQD7NU2rko6NJaUzfdV6xzq2BjqFyOfVMZiJ52WmdUfqbUcbcBAbPsm1TujobpBJtc85f5GHt2acBqPN4jDDSv1nNxRBZITzRVJ1pKepN7aMtkdt7bv0qFlQ0S1kiY1ckSFcTvx8HeeyP0OtVabjJB6EfzM4NHAd7_lykNft9ChTCFUpWYR5-B9eRT6PdBzOnB19puBuoFw%

```

### Etapa 4.5 — Helm Chart umbrella


```sh
# Lint
❯ helm lint helm/tipsbank/
==> Linting helm/tipsbank/
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
❯ helm lint helm/tipsbank/ -f helm/tipsbank/values-prod.yaml
==> Linting helm/tipsbank/
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed


# Renderizar para inspecao
❯ helm template tipsbank helm/tipsbank/ -f helm/tipsbank/values-dev.yaml | head -60
---
# Source: tipsbank/templates/00-namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: dev
---
# Source: tipsbank/templates/00-namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: dev
---
# Source: tipsbank/templates/00-namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tipsbank-auditoria
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: dev
---
# Source: tipsbank/templates/00-namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tipsbank-web
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: dev
---
# Source: tipsbank/templates/00-namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tipsbank-monitoring
  labels:
    app.kubernetes.io/name: tipsbank


❯ helm template tipsbank helm/tipsbank/ -f helm/tipsbank/values-prod.yaml > /tmp/render-prod.yaml
❯ cat /tmp/render-prod.yaml
---
# Source: tipsbank/templates/00-namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
---
# Source: tipsbank/templates/00-namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
---
# Source: tipsbank/templates/00-namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tipsbank-auditoria
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
---
# Source: tipsbank/templates/00-namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tipsbank-web
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
---
# Source: tipsbank/templates/00-namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tipsbank-monitoring
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
---
# Source: tipsbank/templates/auditoria/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tipsbank-auditoria
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Source: tipsbank/templates/auditoria/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-auditoria-ingress
  namespace: tipsbank-auditoria
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector:
    matchLabels:
      app: auditoria
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 8080
          protocol: TCP
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-transacoes
      ports:
        - port: 8080
          protocol: TCP
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-web
      ports:
        - port: 8080
          protocol: TCP
---
# Source: tipsbank/templates/auditoria/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-dns
  namespace: tipsbank-auditoria
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
---
# Source: tipsbank/templates/contas/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Source: tipsbank/templates/contas/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-contas-ingress
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector:
    matchLabels:
      app: api-contas
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 8080
          protocol: TCP
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-transacoes
      ports:
        - port: 8080
          protocol: TCP
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-web
      ports:
        - port: 8080
          protocol: TCP
---
# Source: tipsbank/templates/contas/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-postgres-ingress
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: api-contas
      ports:
        - port: 5432
          protocol: TCP
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-transacoes
      ports:
        - port: 5432
          protocol: TCP
---
# Source: tipsbank/templates/contas/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-contas-egress-postgres
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector:
    matchLabels:
      app: api-contas
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - port: 5432
          protocol: TCP
---
# Source: tipsbank/templates/contas/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-dns
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
---
# Source: tipsbank/templates/transacoes/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Source: tipsbank/templates/transacoes/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-transacoes-ingress
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 8080
          protocol: TCP
---
# Source: tipsbank/templates/transacoes/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-transacoes-egress
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-contas
          podSelector:
            matchLabels:
              app: api-contas
      ports:
        - port: 8080
          protocol: TCP
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-contas
          podSelector:
            matchLabels:
              app: postgres
      ports:
        - port: 5432
          protocol: TCP
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-auditoria
          podSelector:
            matchLabels:
              app: auditoria
      ports:
        - port: 8080
          protocol: TCP
---
# Source: tipsbank/templates/transacoes/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-dns
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
---
# Source: tipsbank/templates/web/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tipsbank-web
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Source: tipsbank/templates/web/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-nginx-controller
  namespace: tipsbank-web
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 8080
          protocol: TCP
---
# Source: tipsbank/templates/web/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-dns
  namespace: tipsbank-web
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
---
# Source: tipsbank/templates/web/netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-web-egress-apis
  namespace: tipsbank-web
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-contas
          podSelector:
            matchLabels:
              app: api-contas
      ports:
        - port: 8080
          protocol: TCP
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-transacoes
          podSelector:
            matchLabels:
              app: api-transacoes
      ports:
        - port: 8080
          protocol: TCP
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tipsbank-auditoria
          podSelector:
            matchLabels:
              app: auditoria
      ports:
        - port: 8080
          protocol: TCP
---
# Source: tipsbank/templates/rbac/serviceaccounts.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-contas-sa
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
---
# Source: tipsbank/templates/rbac/serviceaccounts.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: monitoring-reader-sa
  namespace: tipsbank-monitoring
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
---
# Source: tipsbank/templates/contas/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: contas-db-secret
  namespace: tipsbank-contas
  labels:
    app: postgres
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
type: Opaque
stringData:
  POSTGRES_USER: "tipsbank"
  POSTGRES_PASSWORD: "tipsbank"
  POSTGRES_DB: "tipsbank"
  DB_URL: "postgresql+psycopg://tipsbank:tipsbank@postgres:5432/tipsbank"
---
# Source: tipsbank/templates/contas/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: basic-auth-secret
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
type: Opaque
data:
  auth: YWRtaW46JGFwcjEkVGlwc0JhbmskbWxzV3J6N2JJMVNpcTZuVzl4bzN0Lwo=
---
# Source: tipsbank/templates/rbac/serviceaccounts.yaml
apiVersion: v1
kind: Secret
metadata:
  name: monitoring-reader-token
  namespace: tipsbank-monitoring
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
  annotations:
    kubernetes.io/service-account.name: monitoring-reader-sa
type: kubernetes.io/service-account-token
---
# Source: tipsbank/templates/transacoes/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: transacoes-db-secret
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
type: Opaque
stringData:
  DB_URL: "postgresql+psycopg://tipsbank:tipsbank@postgres.tipsbank-contas.svc.cluster.local:5432/tipsbank"
---
# Source: tipsbank/templates/contas/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init-sql
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
data:
  init.sql: |
    -- TipsBank - schema inicial
    CREATE TABLE IF NOT EXISTS contas (
        id VARCHAR(64) PRIMARY KEY,
        titular VARCHAR(120) NOT NULL,
        documento VARCHAR(14) NOT NULL UNIQUE,
        senha_hash VARCHAR(255) NOT NULL DEFAULT '',
        saldo NUMERIC(15, 2) NOT NULL DEFAULT 0,
        criada_em TIMESTAMP DEFAULT NOW()
    );

    CREATE INDEX IF NOT EXISTS idx_contas_documento ON contas(documento);

    CREATE TABLE IF NOT EXISTS transacoes (
        id VARCHAR(64) PRIMARY KEY,
        origem_id VARCHAR(64) NOT NULL,
        destino_id VARCHAR(64) NOT NULL,
        valor NUMERIC(15, 2) NOT NULL,
        status VARCHAR(20) NOT NULL,
        criada_em TIMESTAMP DEFAULT NOW()
    );

    CREATE INDEX IF NOT EXISTS idx_transacoes_origem ON transacoes(origem_id);
    CREATE INDEX IF NOT EXISTS idx_transacoes_destino ON transacoes(destino_id);

    -- Dados seed (2 contas, senha padrao: "giropops")
    INSERT INTO contas (id, titular, documento, senha_hash, saldo) VALUES
        ('11111111-1111-1111-1111-111111111111', 'Jeferson Fernando', '12345678901',
         '$2b$10$5SvZ8xkTk5HEldopD9Vig.UAu2icE2IxskWxaPtl1PjQ0o3xNfDme', 10000.00),
        ('22222222-2222-2222-2222-222222222222', 'LinuxTips SA',      '98765432100',
         '$2b$10$5SvZ8xkTk5HEldopD9Vig.UAu2icE2IxskWxaPtl1PjQ0o3xNfDme',   500.00)
    ON CONFLICT (documento) DO NOTHING;
---
# Source: tipsbank/templates/contas/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: contas-app-config
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
data:
  LOG_LEVEL: INFO
---
# Source: tipsbank/templates/transacoes/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: transacoes-app-config
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
data:
  CONTAS_URL:    "http://api-contas.tipsbank-contas.svc.cluster.local:8080"
  AUDITORIA_URL: "http://auditoria.tipsbank-auditoria.svc.cluster.local:8080"
  LOG_LEVEL:     "INFO"
  LOG_FILE:      "/var/log/app/app.log"
---
# Source: tipsbank/templates/web/configmap-nginx.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: tipsbank-web
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
data:
  nginx.conf: |
    worker_processes auto;
    pid /tmp/nginx.pid;

    events {
      worker_connections 1024;
    }

    http {
      include /etc/nginx/mime.types;
      default_type application/octet-stream;
      sendfile on;
      keepalive_timeout 65;

      client_body_temp_path /tmp/client_body;
      proxy_temp_path       /tmp/proxy;
      fastcgi_temp_path     /tmp/fastcgi;
      uwsgi_temp_path       /tmp/uwsgi;
      scgi_temp_path        /tmp/scgi;

      upstream contas     { server api-contas.tipsbank-contas.svc.cluster.local:8080; }
      upstream transacoes { server api-transacoes.tipsbank-transacoes.svc.cluster.local:8080; }
      upstream auditoria  { server auditoria.tipsbank-auditoria.svc.cluster.local:8080; }

      server {
        listen 8080;
        server_name _;

        root /usr/share/nginx/html;
        index index.html;

        location = /healthz {
          access_log off;
          return 200 "ok\n";
        }

        location /api/contas/ {
          proxy_pass         http://contas/;
          proxy_http_version 1.1;
          proxy_set_header   Host $host;
          proxy_set_header   X-Real-IP $remote_addr;
          proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /api/transacoes/ {
          proxy_pass         http://transacoes/;
          proxy_http_version 1.1;
          proxy_set_header   Host $host;
          proxy_set_header   X-Real-IP $remote_addr;
          proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /api/auditoria/ {
          proxy_pass         http://auditoria/;
          proxy_http_version 1.1;
          proxy_set_header   Host $host;
          proxy_set_header   X-Real-IP $remote_addr;
          proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location / {
          try_files $uri $uri/ /index.html;
        }
      }
    }
---
# Source: tipsbank/templates/auditoria/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: auditoria-nfs-pvc
  namespace: tipsbank-auditoria
  labels:
    app: auditoria
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: "efs-sc"
  resources:
    requests:
      storage: 20Gi
---
# Source: tipsbank/templates/rbac/roles.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: auditor-readonly
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
rules:
  - apiGroups: [""]
    resources: [pods, pods/log, namespaces, services, configmaps]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, daemonsets]
    verbs: [get, list, watch]
---
# Source: tipsbank/templates/rbac/roles.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: auditor-global-binding
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
subjects:
  - kind: User
    name: auditor-global
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: auditor-readonly
  apiGroup: rbac.authorization.k8s.io
---
# Source: tipsbank/templates/rbac/roles.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sre-admin-binding
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
subjects:
  - kind: User
    name: sre
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
# Source: tipsbank/templates/rbac/serviceaccounts.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: monitoring-reader-binding
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
subjects:
  - kind: ServiceAccount
    name: monitoring-reader-sa
    namespace: tipsbank-monitoring
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
---
# Source: tipsbank/templates/rbac/roles.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
rules:
  - apiGroups: [""]
    resources: [pods, pods/log]
    verbs: [get, list, watch]
---
# Source: tipsbank/templates/rbac/roles.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-operator
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
rules:
  - apiGroups: [""]
    resources: [pods, pods/log]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [pods/exec]
    verbs: [create]
---
# Source: tipsbank/templates/rbac/roles.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: operador-contas-binding
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
subjects:
  - kind: User
    name: operador-contas
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
---
# Source: tipsbank/templates/rbac/roles.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: operador-transacoes-binding
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
subjects:
  - kind: User
    name: operador-transacoes
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-operator
  apiGroup: rbac.authorization.k8s.io
---
# Source: tipsbank/templates/auditoria/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: auditoria
  namespace: tipsbank-auditoria
  labels:
    app: auditoria
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  selector:
    app: auditoria
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
# Source: tipsbank/templates/contas/api-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: api-contas
  namespace: tipsbank-contas
  labels:
    app: api-contas
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  selector:
    app: api-contas
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
# Source: tipsbank/templates/contas/postgres-replica-statefulset.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-replica
  namespace: tipsbank-contas
  labels:
    app: postgres
    role: replica
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  clusterIP: None
  selector:
    app: postgres
    role: replica
  ports:
    - name: postgres
      port: 5432
---
# Source: tipsbank/templates/contas/postgres-statefulset.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: tipsbank-contas
  labels:
    app: postgres
    role: primary
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  clusterIP: None
  selector:
    app: postgres
    role: primary
  ports:
    - name: pg
      port: 5432
      targetPort: 5432
---
# Source: tipsbank/templates/transacoes/deployment-v2.yaml
apiVersion: v1
kind: Service
metadata:
  name: api-transacoes-v2
  namespace: tipsbank-transacoes
  labels:
    app: api-transacoes-v2
    version: v2
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  selector:
    app: api-transacoes-v2
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
# Source: tipsbank/templates/transacoes/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: api-transacoes
  namespace: tipsbank-transacoes
  labels:
    app: api-transacoes
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  selector:
    app: api-transacoes
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
# Source: tipsbank/templates/web/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: tipsbank-web
  labels:
    app: web
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
# Source: tipsbank/templates/daemonset/node-collector.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-collector
  namespace: tipsbank-monitoring
  labels:
    app: node-collector
    team: tipsbank
    env: prod
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  selector:
    matchLabels:
      app: node-collector
  template:
    metadata:
      labels:
        app: node-collector
        team: tipsbank
        env: prod
    spec:
      tolerations:
        - key: "compliance"
          operator: "Equal"
          value: "strict"
          effect: "NoSchedule"
        - key: "node-role.kubernetes.io/control-plane"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - name: collector
          image: busybox:1.36
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
          command:
            - sh
            - -c
            - |
              while true; do
                echo "=== $(date) | node=$(hostname) ==="
                df -h / | tail -1
                free -m | grep Mem
                echo "uptime: $(cat /proc/uptime)"
                sleep 30
              done
          resources:
            requests:
              cpu: "5m"
              memory: "16Mi"
            limits:
              cpu: "20m"
              memory: "32Mi"
          volumeMounts:
            - name: host-root
              mountPath: /host-root
              readOnly: true
      volumes:
        - name: host-root
          hostPath:
            path: /
      terminationGracePeriodSeconds: 10
---
# Source: tipsbank/templates/auditoria/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auditoria
  namespace: tipsbank-auditoria
  labels:
    app: auditoria
    team: tipsbank
    env: prod
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: auditoria
  template:
    metadata:
      labels:
        app: auditoria
        team: tipsbank
        env: prod
    spec:
      securityContext:
        fsGroup: 65532
      containers:
        - name: auditoria
          image: zenardi/tipsbank-auditoria:v1.1.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: DATA_DIR
              value: /data
            - name: LOG_LEVEL
              value: INFO
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: "25m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
          startupProbe:
            httpGet:
              path: /health/startup
              port: 8080
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            periodSeconds: 5
            failureThreshold: 6
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: auditoria-nfs-pvc
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: auditoria
                topologyKey: kubernetes.io/hostname
---
# Source: tipsbank/templates/contas/api-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-contas
  namespace: tipsbank-contas
  labels:
    app: api-contas
    team: tipsbank
    env: prod
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-contas
  template:
    metadata:
      labels:
        app: api-contas
        team: tipsbank
        env: prod
    spec:
      initContainers:
        - name: wait-postgres
          image: busybox:1.36
          command: ['sh', '-c', 'until nc -zw3 postgres 5432; do echo "aguardando postgres..."; sleep 3; done']
      containers:
        - name: api-contas
          image: zenardi/tipsbank-api-contas:v1.1.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: DB_URL
              valueFrom:
                secretKeyRef:
                  name: contas-db-secret
                  key: DB_URL
            - name: LOG_LEVEL
              valueFrom:
                configMapKeyRef:
                  name: contas-app-config
                  key: LOG_LEVEL
          resources:
            requests:
              cpu: "50m"
              memory: "128Mi"
            limits:
              cpu: "200m"
              memory: "256Mi"
          startupProbe:
            httpGet:
              path: /health/startup
              port: 8080
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            periodSeconds: 5
            failureThreshold: 6
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: api-contas
                topologyKey: kubernetes.io/hostname
---
# Source: tipsbank/templates/transacoes/deployment-v2.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-transacoes-v2
  namespace: tipsbank-transacoes
  labels:
    app: api-transacoes-v2
    version: v2
    team: tipsbank
    env: prod
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api-transacoes-v2
  template:
    metadata:
      labels:
        app: api-transacoes-v2
        version: v2
        team: tipsbank
        env: prod
    spec:
      volumes:
        - name: log-volume
          emptyDir: {}
      initContainers:
        - name: wait-postgres
          image: busybox:1.36
          command: ['sh', '-c', 'until nc -zw3 postgres.tipsbank-contas.svc.cluster.local 5432; do echo "aguardando postgres..."; sleep 3; done']
        - name: wait-api-contas
          image: busybox:1.36
          command: ['sh', '-c', 'until wget -qO- http://api-contas.tipsbank-contas.svc.cluster.local:8080/health/ready; do echo "aguardando api-contas..."; sleep 3; done']
      containers:
        - name: api-transacoes
          image: zenardi/tipsbank-api-transacoes:v2.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: DB_URL
              valueFrom:
                secretKeyRef:
                  name: transacoes-db-secret
                  key: DB_URL
            - name: CONTAS_URL
              valueFrom:
                configMapKeyRef:
                  name: transacoes-app-config
                  key: CONTAS_URL
            - name: AUDITORIA_URL
              valueFrom:
                configMapKeyRef:
                  name: transacoes-app-config
                  key: AUDITORIA_URL
            - name: LOG_LEVEL
              valueFrom:
                configMapKeyRef:
                  name: transacoes-app-config
                  key: LOG_LEVEL
            - name: LOG_FILE
              valueFrom:
                configMapKeyRef:
                  name: transacoes-app-config
                  key: LOG_FILE
            - name: APP_VERSION
              value: "v2.0.0"
          volumeMounts:
            - name: log-volume
              mountPath: /var/log/app
          resources:
            requests:
              cpu: "50m"
              memory: "128Mi"
            limits:
              cpu: "200m"
              memory: "256Mi"
          startupProbe:
            httpGet:
              path: /health/startup
              port: 8080
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
        - name: log-forwarder
          image: busybox:1.36
          command: ['sh', '-c', 'until [ -f /var/log/app/app.log ]; do sleep 1; done; tail -F /var/log/app/app.log']
          volumeMounts:
            - name: log-volume
              mountPath: /var/log/app
          resources:
            requests:
              cpu: "5m"
              memory: "16Mi"
            limits:
              cpu: "20m"
              memory: "32Mi"
---
# Source: tipsbank/templates/transacoes/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-transacoes
  namespace: tipsbank-transacoes
  labels:
    app: api-transacoes
    team: tipsbank
    env: prod
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: api-transacoes
  template:
    metadata:
      labels:
        app: api-transacoes
        team: tipsbank
        env: prod
    spec:
      volumes:
        - name: log-volume
          emptyDir: {}
      initContainers:
        - name: wait-postgres
          image: busybox:1.36
          command: ['sh', '-c', 'until nc -zw3 postgres.tipsbank-contas.svc.cluster.local 5432; do echo "aguardando postgres..."; sleep 3; done']
        - name: wait-api-contas
          image: busybox:1.36
          command: ['sh', '-c', 'until wget -qO- http://api-contas.tipsbank-contas.svc.cluster.local:8080/health/ready; do echo "aguardando api-contas..."; sleep 3; done']
      containers:
        - name: api-transacoes
          image: zenardi/tipsbank-api-transacoes:v1.2.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: DB_URL
              valueFrom:
                secretKeyRef:
                  name: transacoes-db-secret
                  key: DB_URL
            - name: CONTAS_URL
              valueFrom:
                configMapKeyRef:
                  name: transacoes-app-config
                  key: CONTAS_URL
            - name: AUDITORIA_URL
              valueFrom:
                configMapKeyRef:
                  name: transacoes-app-config
                  key: AUDITORIA_URL
            - name: LOG_LEVEL
              valueFrom:
                configMapKeyRef:
                  name: transacoes-app-config
                  key: LOG_LEVEL
            - name: LOG_FILE
              valueFrom:
                configMapKeyRef:
                  name: transacoes-app-config
                  key: LOG_FILE
            - name: APP_VERSION
              value: "v1.2.0"
          volumeMounts:
            - name: log-volume
              mountPath: /var/log/app
          resources:
            requests:
              cpu: "50m"
              memory: "128Mi"
            limits:
              cpu: "200m"
              memory: "256Mi"
          startupProbe:
            httpGet:
              path: /health/startup
              port: 8080
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
        - name: log-forwarder
          image: busybox:1.36
          command: ['sh', '-c', 'until [ -f /var/log/app/app.log ]; do sleep 1; done; tail -F /var/log/app/app.log']
          volumeMounts:
            - name: log-volume
              mountPath: /var/log/app
          resources:
            requests:
              cpu: "5m"
              memory: "16Mi"
            limits:
              cpu: "20m"
              memory: "32Mi"
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: api-transacoes
                topologyKey: kubernetes.io/hostname
---
# Source: tipsbank/templates/web/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: tipsbank-web
  labels:
    app: web
    team: tipsbank
    env: prod
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
        team: tipsbank
        env: prod
    spec:
      containers:
        - name: web
          image: zenardi/tipsbank-web:v1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: nginx-config
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
          resources:
            requests:
              cpu: "10m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
          startupProbe:
            httpGet:
              path: /healthz
              port: 8080
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
            failureThreshold: 6
      volumes:
        - name: nginx-config
          configMap:
            name: nginx-config
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: web
                topologyKey: kubernetes.io/hostname
---
# Source: tipsbank/templates/auditoria/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: auditoria
  namespace: tipsbank-auditoria
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: auditoria
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 75
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
---
# Source: tipsbank/templates/contas/api-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-contas
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-contas
  minReplicas: 3
  maxReplicas: 12
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
---
# Source: tipsbank/templates/transacoes/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-transacoes
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-transacoes
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: ContainerResource
      containerResource:
        name: cpu
        container: api-transacoes
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 3
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
---
# Source: tipsbank/templates/contas/postgres-replica-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres-replica
  namespace: tipsbank-contas
  labels:
    app: postgres
    role: replica
    team: tipsbank
    env: prod
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  serviceName: postgres-replica
  replicas: 1
  selector:
    matchLabels:
      app: postgres
      role: replica
  template:
    metadata:
      labels:
        app: postgres
        role: replica
        team: tipsbank
        env: prod
    spec:
      tolerations:
        - key: "compliance"
          operator: "Equal"
          value: "strict"
          effect: "NoSchedule"
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: postgres
              topologyKey: kubernetes.io/hostname
      initContainers:
        - name: wait-primary
          image: busybox:1.36
          command:
            - sh
            - -c
            - "until nc -zw3 postgres.tipsbank-contas.svc.cluster.local 5432; do echo 'aguardando primary...'; sleep 3; done"
      containers:
        - name: postgres-replica
          image: postgres:16-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: "tipsbank"
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: contas-db-secret
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: contas-db-secret
                  key: POSTGRES_PASSWORD
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          startupProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init-sql
              mountPath: /docker-entrypoint-initdb.d/
      volumes:
        - name: init-sql
          configMap:
            name: postgres-init-sql
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: "gp3"
        resources:
          requests:
            storage: 20Gi
---
# Source: tipsbank/templates/contas/postgres-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: tipsbank-contas
  labels:
    app: postgres
    role: primary
    team: tipsbank
    env: prod
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
      role: primary
  template:
    metadata:
      labels:
        app: postgres
        role: primary
        team: tipsbank
        env: prod
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: postgres
              topologyKey: kubernetes.io/hostname
      containers:
        - name: postgres
          image: postgres:16-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: contas-db-secret
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init-sql
              mountPath: /docker-entrypoint-initdb.d/
              readOnly: true
          startupProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "tipsbank", "-d", "tipsbank"]
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
      volumes:
        - name: init-sql
          configMap:
            name: postgres-init-sql
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: "gp3"
        resources:
          requests:
            storage: 20Gi
---
# Source: tipsbank/templates/contas/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tipsbank-api-contas
  namespace: tipsbank-contas
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: basic-auth-secret
    cert-manager.io/cluster-issuer: tipsbank-ca-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.tipsbank.local
      secretName: tipsbank-api-tls
  rules:
    - host: api.tipsbank.local
      http:
        paths:
          - path: /contas(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-contas
                port:
                  number: 8080
---
# Source: tipsbank/templates/monitoring/grafana-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: tipsbank-monitoring
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: tipsbank-ca-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - grafana.tipsbank.local
      secretName: grafana-tls
  rules:
    - host: grafana.tipsbank.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-grafana
                port:
                  number: 80
---
# Source: tipsbank/templates/monitoring/grafana-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: tipsbank-monitoring
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: tipsbank-ca-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - prometheus.tipsbank.local
      secretName: prometheus-tls
  rules:
    - host: prometheus.tipsbank.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-prometheus
                port:
                  number: 9090
---
# Source: tipsbank/templates/monitoring/grafana-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: alertmanager
  namespace: tipsbank-monitoring
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: tipsbank-ca-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - alertmanager.tipsbank.local
      secretName: alertmanager-tls
  rules:
    - host: alertmanager.tipsbank.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-alertmanager
                port:
                  number: 9093
---
# Source: tipsbank/templates/transacoes/ingress-canary.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tipsbank-api-transacoes-canary
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "10"
    nginx.ingress.kubernetes.io/canary-by-header: "X-Canary"
    nginx.ingress.kubernetes.io/canary-by-header-value: "always"
spec:
  ingressClassName: nginx
  rules:
    - host: api.tipsbank.local
      http:
        paths:
          - path: /transacoes(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-transacoes-v2
                port:
                  number: 8080
---
# Source: tipsbank/templates/transacoes/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tipsbank-api-transacoes
  namespace: tipsbank-transacoes
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/affinity: cookie
    nginx.ingress.kubernetes.io/affinity-mode: persistent
    nginx.ingress.kubernetes.io/session-cookie-name: TIPSBANK_ROUTE
    nginx.ingress.kubernetes.io/session-cookie-max-age: "3600"
spec:
  ingressClassName: nginx
  rules:
    - host: api.tipsbank.local
      http:
        paths:
          - path: /transacoes(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-transacoes
                port:
                  number: 8080
---
# Source: tipsbank/templates/web/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tipsbank-app
  namespace: tipsbank-web
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
  annotations:
    nginx.ingress.kubernetes.io/limit-rps: "50"
    nginx.ingress.kubernetes.io/limit-req-status-code: "429"
    cert-manager.io/cluster-issuer: tipsbank-ca-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - app.tipsbank.local
      secretName: tipsbank-app-tls
  rules:
    - host: app.tipsbank.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 8080
---
# Source: tipsbank/templates/policies/kyverno-generate-netpol.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-default-deny-netpol
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  background: false
  rules:
    - name: gen-netpol-default-deny
      match:
        any:
          - resources:
              kinds: [Namespace]
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-public
                - kube-node-lease
                - default
                - kyverno
                - cert-manager
                - ingress-nginx
                - tipsbank-monitoring
      generate:
        kind: NetworkPolicy
        apiVersion: networking.k8s.io/v1
        name: default-deny
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes: [Ingress, Egress]
---
# Source: tipsbank/templates/policies/kyverno-mutate-securitycontext.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: mutate-security-context
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  background: false
  rules:
    - name: add-default-securitycontext
      match:
        any:
          - resources:
              kinds: [Pod]
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                securityContext:
                  +(runAsNonRoot): true
                  +(readOnlyRootFilesystem): true
                  +(allowPrivilegeEscalation): false
---
# Source: tipsbank/templates/policies/kyverno-validate-no-latest.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Toda imagem precisa de uma tag explicita (nao pode ser :latest e nao pode estar sem tag)."
        pattern:
          spec:
            containers:
              - name: "*"
                image: "!*:latest & *:*"
---
# Source: tipsbank/templates/policies/kyverno-validate-no-root.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-root-user
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-runasnonroot
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Pods nao podem rodar como root (runAsUser != 0). UID 0 e proibido."
        pattern:
          spec:
            =(securityContext):
              =(runAsUser): ">0"
            containers:
              - name: "*"
                =(securityContext):
                  =(runAsUser): ">0"
---
# Source: tipsbank/templates/policies/kyverno-validate-registry.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: allowed-image-registries
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-registry
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Imagem fora dos registries confiaveis."
        pattern:
          spec:
            containers:
              - name: "*"
                image: "zenardi/* | gcr.io/distroless/* | registry.k8s.io/* | quay.io/jetstack/* | quay.io/kyverno/* | ghcr.io/kyverno/* | nginxinc/nginx-unprivileged:* | postgres:* | busybox:*"
---
# Source: tipsbank/templates/policies/kyverno-validate-require-labels.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
  labels:
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-labels-app-team-env
      match:
        any:
          - resources:
              kinds: [Deployment, StatefulSet, DaemonSet]
      validate:
        message: "Workloads precisam das labels: app, team, env."
        pattern:
          metadata:
            labels:
              app: "?*"
              team: "?*"
              env: "?*"
---
# Source: tipsbank/templates/monitoring/prometheusrule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: tipsbank-slo-alerts
  namespace: tipsbank-monitoring
  labels:
    release: kube-prometheus-stack
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  groups:
    - name: tipsbank.slo
      interval: 30s
      rules:
        - alert: TipsBankApiDown
          expr: up{job=~"tipsbank-contas/api-contas|tipsbank-transacoes/api-transacoes|tipsbank-auditoria/auditoria"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "API {{ $labels.job }} esta down"
            description: "Target {{ $labels.instance }} sem resposta ha mais de 2 minutos."
        - alert: TipsBankP99Alto
          expr: |
            histogram_quantile(0.99,
              sum by (job, le) (
                rate(http_request_duration_seconds_bucket{namespace=~"tipsbank-.*"}[5m])
              )
            ) > 0.5
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "P99 de latencia acima de 500ms em {{ $labels.job }}"
            description: "P99 atual = {{ $value | humanizeDuration }}"
        - alert: TipsBankErroAltoApi
          expr: |
            (
              sum by (job) (rate(http_requests_total{status=~"5..",namespace=~"tipsbank-.*"}[3m]))
              /
              sum by (job) (rate(http_requests_total{namespace=~"tipsbank-.*"}[3m]))
            ) > 0.05
          for: 3m
          labels:
            severity: critical
          annotations:
            summary: "Taxa de erros 5xx > 5% em {{ $labels.job }}"
            description: "Taxa atual: {{ $value | humanizePercentage }}"
        - alert: TipsBankPodCrashLoop
          expr: increase(kube_pod_container_status_restarts_total{namespace=~"tipsbank-.*"}[10m]) > 3
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} em CrashLoop"
            description: "{{ $value }} restarts nos ultimos 10 minutos no namespace {{ $labels.namespace }}."
---
# Source: tipsbank/templates/auditoria/servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: auditoria
  namespace: tipsbank-auditoria
  labels:
    release: kube-prometheus-stack
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  selector:
    matchLabels:
      app: auditoria
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
---
# Source: tipsbank/templates/contas/api-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api-contas
  namespace: tipsbank-contas
  labels:
    release: kube-prometheus-stack
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  selector:
    matchLabels:
      app: api-contas
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
---
# Source: tipsbank/templates/transacoes/servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api-transacoes
  namespace: tipsbank-transacoes
  labels:
    release: kube-prometheus-stack
    app.kubernetes.io/name: tipsbank
    app.kubernetes.io/instance: tipsbank
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/managed-by: Helm
    team: tipsbank
    env: prod
spec:
  selector:
    matchLabels:
      app: api-transacoes
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

