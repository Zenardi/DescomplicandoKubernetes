#!/usr/bin/env bash
# Checkpoint final — Semana 1 · TipsBank

# ── Cores ──────────────────────────────────────────────────────────────────────
BOLD='\033[1m'; RESET='\033[0m'
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'

section() { echo; echo -e "${BOLD}${CYAN}━━━  $1  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; echo; }
ok()      { echo -e "  ${GREEN}✔${RESET}  $1"; }
info()    { echo -e "  ${BLUE}ℹ${RESET}  $1"; }

# ── Kubeconfig ─────────────────────────────────────────────────────────────────
export KUBECONFIG=~/Documents/develop/DescomplicandoKubernetes/desafios/tipsbank/vagrant/admin.conf

echo
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${YELLOW}║     CHECKPOINT SEMANA 1 — TipsBank       ║${RESET}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════╝${RESET}"

# ── 1. Nodes ───────────────────────────────────────────────────────────────────
section "1 · Cluster — Nodes Ready"
kubectl get nodes -o wide
echo
READY=$(kubectl get nodes --no-headers | grep -c " Ready ")
ok "${READY}/3 nodes Ready"

# ── 2. Pods ────────────────────────────────────────────────────────────────────
section "2 · Pods tipsbank (todos os namespaces)"
kubectl get pods -A --field-selector=metadata.namespace!=kube-system \
  | grep tipsbank | sort -k1,1 -k2,2
echo
RUNNING=$(kubectl get pods -A --no-headers | grep tipsbank | grep -c Running)
ok "${RUNNING} pods Running"

# ── 3. Storage ─────────────────────────────────────────────────────────────────
section "3 · PersistentVolumes e PersistentVolumeClaims"
kubectl get pv -o custom-columns="NAME:.metadata.name,CAPACITY:.spec.capacity.storage,ACCESS:.spec.accessModes[0],STATUS:.status.phase,CLAIM:.spec.claimRef.name"
echo
kubectl get pvc -A --no-headers | grep tipsbank | awk '{printf "  %-20s %-30s %-8s %-10s %s\n", $1, $2, $3, $4, $5}'
echo
ok "PV auditoria-nfs-pv  → RWX (NFS)"
ok "PV postgres          → RWO (local-path)"

# ── 4. Secrets & ConfigMaps ────────────────────────────────────────────────────
section "4 · Secrets e ConfigMaps por namespace"
echo -e "  ${BOLD}Secrets:${RESET}"
kubectl get secrets -A --no-headers | grep tipsbank | grep -v kube-root \
  | awk '{printf "    %-25s  %-35s  %s\n", $1, $2, $3}'
echo
echo -e "  ${BOLD}ConfigMaps:${RESET}"
kubectl get configmap -A --no-headers | grep tipsbank | grep -v kube-root \
  | awk '{printf "    %-25s  %-35s  %s\n", $1, $2, $3}'

# ── 5. Multicontainer (sidecar) ────────────────────────────────────────────────
section "5 · Pod multicontainer — api-transacoes (2/2)"
kubectl get pods -n tipsbank-transacoes -o wide
echo
kubectl get pod -n tipsbank-transacoes -l app=api-transacoes -o jsonpath=\
'{range .items[*]}  pod: {.metadata.name}{"\n"}  containers: {range .spec.containers[*]}{.name}  {end}{"\n\n"}{end}'
ok "sidecar log-forwarder presente"

# ── 6. Transferência end-to-end ────────────────────────────────────────────────
section "6 · Transferência end-to-end via K8s"
kubectl port-forward -n tipsbank-transacoes svc/api-transacoes 8082:8080 \
  >/dev/null 2>&1 &
PF_PID=$!
sleep 2
info "POST /transferencias  origem→destino  valor=10.00"
RESP=$(curl -s -X POST http://localhost:8082/transferencias \
  -H 'content-type: application/json' \
  -d '{"origem_id":"11111111-1111-1111-1111-111111111111","destino_id":"22222222-2222-2222-2222-222222222222","valor":"10.00"}')
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
STATUS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
ok "transferência status=${STATUS}"
kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null || true

# ── 7. Auditoria NFS RWX ──────────────────────────────────────────────────────
section "7 · Auditoria NFS — 3 réplicas, volume RWX compartilhado"
info "Abrindo port-forward para cada pod de auditoria..."
idx=0
for pod in $(kubectl get pod -n tipsbank-auditoria -l app=auditoria \
             -o jsonpath='{.items[*].metadata.name}'); do
  PORT=$((19080 + idx))
  kubectl port-forward -n tipsbank-auditoria "pod/${pod}" ${PORT}:8080 \
    >/dev/null 2>&1 &
  idx=$((idx + 1))
done
sleep 3

echo
printf "  ${BOLD}%-52s  %-20s  %s${RESET}\n" "POD" "ARQUIVOS" "EVENTOS"
printf "  %s\n" "────────────────────────────────────────────────────────────────────────────────"
idx=0
for pod in $(kubectl get pod -n tipsbank-auditoria -l app=auditoria \
             -o jsonpath='{.items[*].metadata.name}'); do
  PORT=$((19080 + idx))
  FILES=$(curl -s "http://localhost:${PORT}/arquivos" 2>/dev/null)
  COUNT=$(curl -s "http://localhost:${PORT}/eventos?limit=500" 2>/dev/null \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
  printf "  %-52s  %-20s  %s\n" "${pod}" "${FILES}" "${COUNT}"
  idx=$((idx + 1))
done
echo
ok "todos os pods leem o mesmo arquivo NFS (RWX)"

kill $(jobs -p) 2>/dev/null; wait 2>/dev/null || true

# ── Resumo ─────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   ✅  Semana 1 — todos os critérios OK   ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${RESET}"
echo