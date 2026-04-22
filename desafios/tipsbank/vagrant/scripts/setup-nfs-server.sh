#!/usr/bin/env bash
# Instala e configura nfs-kernel-server no worker1.
# Executado manualmente: vagrant ssh worker1 -- sudo bash /vagrant/scripts/setup-nfs-server.sh
# ou via: vagrant provision worker1 --provision-with nfs-server  (se adicionado ao Vagrantfile)
set -euo pipefail

NFS_EXPORT_DIR="/srv/nfs/auditoria"
NFS_CLIENT_CIDR="192.168.56.0/24"
NFS_UID=65532  # nonroot — UID/GID da imagem Chainguard

echo ">>> [nfs-server] Instalando nfs-kernel-server e nfs-common"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-kernel-server nfs-common

echo ">>> [nfs-server] Criando diretório de exportação: ${NFS_EXPORT_DIR}"
mkdir -p "${NFS_EXPORT_DIR}"
chown -R ${NFS_UID}:${NFS_UID} "${NFS_EXPORT_DIR}"
chmod 775 "${NFS_EXPORT_DIR}"

echo ">>> [nfs-server] Configurando /etc/exports"
# Idempotente: remove entrada existente antes de adicionar
sed -i "\|${NFS_EXPORT_DIR}|d" /etc/exports
echo "${NFS_EXPORT_DIR} ${NFS_CLIENT_CIDR}(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports

echo ">>> [nfs-server] Publicando exports"
exportfs -rav

echo ">>> [nfs-server] Habilitando e (re)iniciando nfs-kernel-server"
systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server

echo ">>> [nfs-server] Verificando exportação"
showmount -e localhost

echo ">>> [nfs-server] Concluído. NFS exportando ${NFS_EXPORT_DIR} para ${NFS_CLIENT_CIDR}"
