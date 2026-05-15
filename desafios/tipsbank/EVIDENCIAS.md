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


