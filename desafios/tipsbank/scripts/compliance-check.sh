#!/usr/bin/env bash
# Compliance check TipsBank — valida os 7 checkpoints do MANUAL-ALUNO.md.
set -uo pipefail

APP_NS=(tipsbank-contas tipsbank-transacoes tipsbank-auditoria tipsbank-web)
NS_REGEX="^(tipsbank-contas|tipsbank-transacoes|tipsbank-auditoria|tipsbank-web)$"

# Registries confiaveis (usados por imagens de app + initContainers/sidecars TipsBank)
REGISTRY_REGEX='ghcr\.io/zenardi|zenardi/tipsbank|quay\.io/jetstack|registry\.k8s\.io|gcr\.io/distroless|quay\.io/kyverno|ghcr\.io/kyverno|nginxinc/nginx-unprivileged|^postgres:|^busybox:'

IMAGES_PROD=(
  "zenardi/tipsbank-api-contas:v1.1.0"
  "zenardi/tipsbank-api-transacoes:v1.2.0"
  "zenardi/tipsbank-auditoria:v1.1.0"
  "zenardi/tipsbank-web:v1.0.0"
)

PASS=0; FAIL=0
ok()   { echo "  OK:   $*"; ((PASS++)) || true; }
fail() { echo "  FAIL: $*"; ((FAIL++)) || true; }

echo "================================================================"
echo "TipsBank — Compliance Check  ($(date -u +%FT%TZ))"
echo "================================================================"

# ------------------------------------------------------------------ #
echo
echo "## 1. Imagens FORA do registry confiavel (namespaces de app)"
echo "   (kube-system / kyverno / tipsbank-monitoring sao 3rd party — excluidos)"
IMGS_FAIL=""
for ns in "${APP_NS[@]}"; do
  OUT=$(kubectl get pods -n "$ns" -o json 2>/dev/null \
    | jq -r '.items[] |
        .metadata.namespace + "/" + .metadata.name as $pod |
        ((.spec.initContainers // []) + .spec.containers)[] |
        $pod + "\t" + .image' \
    | awk -F"\t" -v re="$REGISTRY_REGEX" '$2 !~ re {print $0}' || true)
  [ -n "$OUT" ] && IMGS_FAIL+="$OUT"$'\n'
done
if [ -z "$IMGS_FAIL" ]; then
  ok "Nenhuma imagem fora do registry confiavel"
else
  fail "Imagens nao autorizadas encontradas:"
  echo "$IMGS_FAIL"
fi

# ------------------------------------------------------------------ #
echo
echo "## 2. Pods rodando como root (tipsbank-*)"
ROOT_PODS=$(kubectl get pods -A -o json \
  | jq -r '[.items[]
      | select(.metadata.namespace | test("^tipsbank"))
      | select(
          (.spec.securityContext.runAsUser == 0) or
          ((.spec.containers[].securityContext.runAsUser // 65532) == 0)
        )
      | "\(.metadata.namespace)/\(.metadata.name)"] | .[]')
if [ -z "$ROOT_PODS" ]; then
  ok "Nenhum pod rodando como root"
else
  fail "Pods rodando como root:"
  echo "$ROOT_PODS"
fi

# ------------------------------------------------------------------ #
echo
echo "## 3. Workloads SEM livenessProbe no container principal"
echo "   (verifica containers[0]; sidecar log-forwarder e afins sao ignorados)"
NO_LIVENESS=$(kubectl get deploy,sts,ds -A -o json \
  | jq -r --arg re "$NS_REGEX" '[.items[]
      | select(.metadata.namespace | test($re))
      | select(.spec.template.spec.containers[0].livenessProbe == null)
      | "\(.metadata.namespace)/\(.metadata.name)"] | .[]')
if [ -z "$NO_LIVENESS" ]; then
  ok "Todos os workloads possuem livenessProbe"
else
  fail "Workloads sem livenessProbe:"
  echo "$NO_LIVENESS"
fi

# ------------------------------------------------------------------ #
echo
echo "## 4. Workloads SEM resources.limits no container principal"
NO_LIMITS=$(kubectl get deploy,sts,ds -A -o json \
  | jq -r --arg re "$NS_REGEX" '[.items[]
      | select(.metadata.namespace | test($re))
      | select(.spec.template.spec.containers[0].resources.limits == null)
      | "\(.metadata.namespace)/\(.metadata.name)"] | .[]')
if [ -z "$NO_LIMITS" ]; then
  ok "Todos os workloads possuem resources.limits"
else
  fail "Workloads sem resources.limits:"
  echo "$NO_LIMITS"
fi

# ------------------------------------------------------------------ #
echo
echo "## 5. Policies Kyverno ativas"
while IFS= read -r line; do
  name=$(echo "$line" | jq -r '.name')
  ready=$(echo "$line" | jq -r '.ready')
  if [ "$ready" = "True" ]; then
    ok "ClusterPolicy/$name"
  else
    fail "ClusterPolicy/$name (Ready=$ready)"
  fi
done < <(kubectl get cpol -o json \
  | jq -c '.items[] | {
      name: .metadata.name,
      ready: (.status.conditions // []
              | map(select(.type == "Ready"))
              | first
              | .status // "Unknown")
    }')

# ------------------------------------------------------------------ #
echo
echo "## 6. NetworkPolicies por namespace"
ALL_NETPOL=true
for ns in "${APP_NS[@]}"; do
  COUNT=$(kubectl get netpol -n "$ns" --no-headers 2>/dev/null | wc -l)
  if [ "$COUNT" -ge 2 ]; then
    ok "$ns: $COUNT NetworkPolicies"
  else
    fail "$ns: apenas $COUNT NetworkPolicy(ies) — esperado >=2"
    ALL_NETPOL=false
    kubectl get netpol -n "$ns" 2>/dev/null
  fi
done

# ------------------------------------------------------------------ #
echo
echo "## 7. Imagens assinadas (Cosign)"
for img in "${IMAGES_PROD[@]}"; do
  if cosign verify "$img" \
       --certificate-identity-regexp '.*' \
       --certificate-oidc-issuer-regexp '.*' \
       >/dev/null 2>&1; then
    ok "$img"
  else
    fail "$img — rode: cosign sign $img"
  fi
done

# ------------------------------------------------------------------ #
echo
echo "================================================================"
echo "Resultado: ${PASS} OK | ${FAIL} FAIL"
[ "$FAIL" -eq 0 ] && echo "STATUS: PASS" || echo "STATUS: FAIL"
echo "================================================================"
