#!/usr/bin/env bash
# provision-common.sh — executado em TODOS os nodes (controlplane, worker1, worker2)
set -euo pipefail

NODE_IP="${NODE_IP:?NODE_IP não definido}"

echo ">>> [common] /etc/hosts — registrando todos os nodes"
# Remove entradas duplicadas caso o script seja re-executado
sed -i '/192\.168\.56\./d' /etc/hosts
cat >> /etc/hosts <<'EOF'
192.168.56.10 controlplane
192.168.56.11 worker1
192.168.56.12 worker2
EOF

echo ">>> [common] Desabilitando swap (requisito do kubelet)"
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo ">>> [common] Módulos do kernel: overlay e br_netfilter"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo ">>> [common] Parâmetros sysctl para roteamento de pacotes"
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo ">>> [common] Instalando containerd"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
rm -f /etc/apt/keyrings/docker.gpg
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --batch --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
apt-get install -y -qq containerd.io

echo ">>> [common] Configurando containerd (SystemdCgroup = true)"
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo ">>> [common] Instalando kubeadm, kubelet, kubectl (k8s 1.32)"
KUBE_VERSION="1.32"
apt-get install -y -qq apt-transport-https
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
  | gpg --batch --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo ">>> [common] Apontando kubelet para a interface privada (${NODE_IP})"
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet
systemctl enable kubelet

# ─── Rota persistente para o service CIDR ─────────────────────────────────────
# O pod-cidr 10.0.0.0/8 inclui 10.0.2.0/24 (NAT do VirtualBox), fazendo o
# KUBE-MARK-MASQ não disparar para tráfego de workers → controlplane via ClusterIP.
# Esta rota força o kernel a usar enp0s8 (host-only) como saída para service IPs,
# garantindo source IP correto (192.168.56.x) e resposta do controlplane.
echo ">>> [common] Rota persistente para service CIDR via enp0s8 (${NODE_IP})"
cat > /etc/netplan/99-k8s-routes.yaml <<EOF
network:
  version: 2
  ethernets:
    enp0s8:
      routes:
        - to: 10.96.0.0/12
          via: 0.0.0.0
          on-link: true
EOF
netplan apply 2>/dev/null || true

echo ">>> [common] Provisionamento comum concluído (node: $(hostname), ip: ${NODE_IP})"
