#!/usr/bin/env bash
# provision-controlplane.sh — executado SOMENTE no control-plane
# Idempotente: cada bloco verifica se já foi executado antes de rodar.
set -euo pipefail

NODE_IP="${NODE_IP:?NODE_IP não definido}"
POD_CIDR="10.0.0.0/8"
export KUBECONFIG=/etc/kubernetes/admin.conf

# ─── kubeadm init ────────────────────────────────────────────────────────────
if [ -f /etc/kubernetes/admin.conf ]; then
  echo ">>> [controlplane] Cluster já inicializado — pulando kubeadm init"
else
  echo ">>> [controlplane] Inicializando cluster"
  kubeadm init \
    --apiserver-advertise-address="${NODE_IP}" \
    --pod-network-cidr="${POD_CIDR}" \
    --node-name=controlplane \
    2>&1 | tee /vagrant/kubeadm-init.log
fi

# ─── kubeconfig ──────────────────────────────────────────────────────────────
echo ">>> [controlplane] Configurando kubeconfig para usuário vagrant"
mkdir -p /home/vagrant/.kube
cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# Exporta para /vagrant (mapeada para o host)
# O host pode usar: export KUBECONFIG=vagrant/admin.conf
cp /etc/kubernetes/admin.conf /vagrant/admin.conf

# ─── join command ─────────────────────────────────────────────────────────────
echo ">>> [controlplane] Salvando join command para os workers"
kubeadm token create --print-join-command > /vagrant/join-command.sh
chmod +x /vagrant/join-command.sh

# ─── Cilium CLI ──────────────────────────────────────────────────────────────
if command -v cilium &>/dev/null; then
  echo ">>> [controlplane] Cilium CLI já instalado ($(cilium version --client 2>/dev/null | head -1)) — pulando"
else
  echo ">>> [controlplane] Instalando Cilium CLI"
  CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
  echo "    versão: ${CILIUM_CLI_VERSION}"
  curl -fsSL --remote-name-all \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz.sha256sum"
  sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
  tar xzf cilium-linux-amd64.tar.gz -C /usr/local/bin
  rm -f cilium-linux-amd64.tar.gz cilium-linux-amd64.tar.gz.sha256sum
fi

# ─── Cilium install ──────────────────────────────────────────────────────────
if kubectl get daemonset cilium -n kube-system &>/dev/null 2>&1; then
  echo ">>> [controlplane] Cilium já instalado no cluster — pulando"
else
  echo ">>> [controlplane] Instalando Cilium CNI"
  cilium install \
    --helm-set ipam.mode=kubernetes \
    2>&1 | tee /vagrant/cilium-install.log
fi

echo ">>> [controlplane] Aguardando Cilium ficar Ready"
cilium status --wait

# ─── Verificação final ───────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo " Control-plane pronto!"
echo "=========================================="
kubectl get nodes -o wide
echo ""
kubectl get pods -n kube-system
echo ""
echo " Para acessar do host:"
echo "   export KUBECONFIG=\$(pwd)/vagrant/admin.conf"
echo "=========================================="
