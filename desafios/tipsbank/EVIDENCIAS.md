# TipsBank — Evidências de Entrega

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
