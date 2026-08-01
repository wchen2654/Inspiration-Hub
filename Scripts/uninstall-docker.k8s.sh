#!/usr/bin/env bash
#
# uninstall-docker-k8s.sh
#
# Completely removes Docker Engine and Kubernetes (kubeadm/kubelet/kubectl)
# from an Ubuntu 24.04 node, including packages, repos, keys, configs,
# and data directories. Use this before a clean reinstall, or if you
# just want everything gone.
#
# Usage:
#   chmod +x uninstall-docker-k8s.sh
#   sudo ./uninstall-docker-k8s.sh
#
# WARNING: this deletes all local containers, images, volumes, and any
# Kubernetes cluster state on this node. There is no undo.

set -uo pipefail   # no -e: keep going even if some steps fail (nothing to remove, etc.)

if [[ $EUID -ne 0 ]]; then
  echo "Please run this script with sudo/root." >&2
  exit 1
fi

read -rp "This will permanently remove Docker and Kubernetes from this node. Continue? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo "==> 1. Resetting kubeadm (if a cluster was initialized on this node)"
if command -v kubeadm >/dev/null 2>&1; then
  kubeadm reset -f || true
fi

echo "==> 2. Stopping services"
systemctl stop kubelet 2>/dev/null || true
systemctl stop docker 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true

echo "==> 3. Removing Kubernetes packages"
apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
apt-get purge -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true

echo "==> 4. Removing Docker packages"
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-doc docker-compose docker-compose-v2 podman-docker 2>/dev/null || true

echo "==> 5. Autoremoving now-unused dependencies"
apt-get autoremove -y

echo "==> 6. Removing repo definitions and keys"
rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/docker.asc
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "==> 7. Removing data directories and configs"
rm -rf /var/lib/docker
rm -rf /var/lib/containerd
rm -rf /etc/docker
rm -rf /etc/containerd
rm -rf /etc/kubernetes
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf "$HOME/.kube"
rm -f /etc/modules-load.d/k8s.conf
rm -f /etc/sysctl.d/k8s.conf
rm -f /etc/cni/net.d/* 2>/dev/null

echo "==> 8. Cleaning up leftover network interfaces (cni0, flannel.1, docker0, etc.)"
for iface in cni0 flannel.1 docker0; do
  ip link delete "$iface" 2>/dev/null || true
done

echo "==> 9. Re-enabling swap entry in fstab (commented lines only — review before re-enabling)"
sed -i '/ swap / s/^#//' /etc/fstab

apt-get update

echo ""
echo "==> Done. Docker and Kubernetes have been removed from this node."
echo "Run install-docker-k8s.sh again for a clean install."
