#!/usr/bin/env bash
# provision-worker.sh — executado em worker1 e worker2
# Idempotente: verifica se o node já está no cluster antes de fazer join.
set -euo pipefail

NODE_IP="${NODE_IP:?NODE_IP não definido}"
NODE_NAME="${NODE_NAME:?NODE_NAME não definido}"

# ─── Verifica se já está no cluster ──────────────────────────────────────────
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo ">>> [${NODE_NAME}] Já está no cluster — pulando kubeadm join"
  exit 0
fi

# ─── Aguarda o join command do control-plane ──────────────────────────────────
echo ">>> [${NODE_NAME}] Aguardando join-command.sh do control-plane..."
TIMEOUT=300
ELAPSED=0
until [ -f /vagrant/join-command.sh ]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "ERRO: /vagrant/join-command.sh não encontrado após ${TIMEOUT}s."
    exit 1
  fi
  echo "    ... aguardando (${ELAPSED}s / ${TIMEOUT}s)"
done

# ─── kubeadm join ─────────────────────────────────────────────────────────────
echo ">>> [${NODE_NAME}] Executando kubeadm join (ip: ${NODE_IP})"
bash /vagrant/join-command.sh

echo ""
echo "=========================================="
echo " ${NODE_NAME} (${NODE_IP}) joined ao cluster!"
echo "=========================================="
