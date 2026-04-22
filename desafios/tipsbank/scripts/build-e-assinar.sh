#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# TipsBank - script de referencia para build, scan e assinatura das imagens.
# Este script NAO deve ser apenas executado cegamente pelos alunos.
# Ele serve como GUIA - o aluno precisa entender cada passo
# (Day-13 do DK8s: Distroless, Trivy, Docker Scout, Cosign).
# -----------------------------------------------------------------------------
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io/zenardi}"
TAG="${TAG:-v1.0.0}"
APPS=(api-contas api-transacoes auditoria)

cd "$(dirname "$0")/.."

echo "==> 1. Build das imagens (python:3.11-slim builder + Distroless runtime)"
for app in "${APPS[@]}"; do
    img="${REGISTRY}/tipsbank-${app}:${TAG}"
    echo "  -> ${img}"
    docker build -t "${img}" "apps/${app}"
done

echo ""
echo "==> 2. Scan de vulnerabilidades com Trivy"
for app in "${APPS[@]}"; do
    img="${REGISTRY}/tipsbank-${app}:${TAG}"
    echo "  -> ${img}"
    trivy image --severity HIGH,CRITICAL --exit-code 1 "${img}"
done

echo ""
echo "==> 3. Scan com Docker Scout (opcional, tambem cobre o Day-13)"
for app in "${APPS[@]}"; do
    img="${REGISTRY}/tipsbank-${app}:${TAG}"
    echo "  -> ${img}"
    docker scout cves "${img}" || true
done

echo ""
echo "==> 4. Push para o registry"
for app in "${APPS[@]}"; do
    img="${REGISTRY}/tipsbank-${app}:${TAG}"
    docker push "${img}"
done

echo ""
echo "==> 5. Assinatura com Cosign (keyless - OIDC)"
for app in "${APPS[@]}"; do
    img="${REGISTRY}/tipsbank-${app}:${TAG}"
    echo "  -> assinando ${img}"
    COSIGN_EXPERIMENTAL=1 cosign sign --yes "${img}"
done

echo ""
echo "==> 6. Verificando assinaturas"
for app in "${APPS[@]}"; do
    img="${REGISTRY}/tipsbank-${app}:${TAG}"
    COSIGN_EXPERIMENTAL=1 cosign verify "${img}" \
        --certificate-identity-regexp '.*' \
        --certificate-oidc-issuer-regexp '.*' > /dev/null && \
        echo "  OK: ${img}"
done

echo ""
echo "==> FIM. Imagens prontas, escaneadas e assinadas."
