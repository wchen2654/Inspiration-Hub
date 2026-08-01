#!/usr/bin/env bash
#
# install-docker-k8s.sh
#
# Installs Docker Engine + containerd, then kubeadm/kubelet/kubectl,
# on Ubuntu 24.04 (Noble). Run on every node that will join the cluster.
#
# Usage:
#   chmod +x install-docker-k8s.sh
#   sudo ./install-docker-k8s.sh              # fresh install
#   sudo ./install-docker-k8s.sh --reinstall   # wipe any existing Docker/K8s
#                                               # install first, then install clean
#
# After it finishes:
#   - On the control-plane node only, run:
#       sudo kubeadm init --pod-network-cidr=10.244.0.0/16
#       mkdir -p $HOME/.kube
#       sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
#       sudo chown $(id -u):$(id -g) $HOME/.kube/config
#       kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
#   - On worker nodes, run the "kubeadm join ..." command printed by kubeadm init
#     (or generate it later on the control-plane with:
#       kubeadm token create --print-join-command)

set -euo pipefail

# --- Config -----------------------------------------------------------
K8S_VERSION="v1.34"   # Kubernetes minor version line, e.g. v1.34 or v1.35
                       # Must match across ALL nodes in the cluster.

# --- Must run as root ---------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Please run this script with sudo/root." >&2
  exit 1
fi

ORIGINAL_USER="${SUDO_USER:-$USER}"

# --- Optional full purge before reinstalling ---------------------------
REINSTALL=false
if [[ "${1:-}" == "--reinstall" ]]; then
  REINSTALL=true
fi

if [[ "$REINSTALL" == true ]]; then
  echo "==> --reinstall passed: purging any existing Docker/Kubernetes install first"

  if command -v kubeadm >/dev/null 2>&1; then
    kubeadm reset -f || true
  fi

  systemctl stop kubelet 2>/dev/null || true
  systemctl stop docker 2>/dev/null || true
  systemctl stop containerd 2>/dev/null || true

  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
  apt-get purge -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    docker-compose-plugin docker.io docker-doc docker-compose docker-compose-v2 \
    podman-docker 2>/dev/null || true
  apt-get autoremove -y

  rm -f /etc/apt/sources.list.d/docker.list
  rm -f /etc/apt/sources.list.d/kubernetes.list
  rm -f /etc/apt/keyrings/docker.asc
  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/containerd
  rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd "$HOME/.kube"
  rm -f /etc/modules-load.d/k8s.conf /etc/sysctl.d/k8s.conf
  rm -f /etc/cni/net.d/* 2>/dev/null

  for iface in cni0 flannel.1 docker0; do
    ip link delete "$iface" 2>/dev/null || true
  done

  apt-get update
  echo "==> Purge complete. Proceeding with clean install."
fi

echo "==> 1. Removing old/conflicting Docker packages"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done

echo "==> 2. Installing Docker Engine"
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> 3. Verifying Docker and enabling non-root usage for ${ORIGINAL_USER}"
docker run --rm hello-world
usermod -aG docker "${ORIGINAL_USER}"

echo "==> 4. Disabling swap (required by kubelet)"
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo "==> 5. Loading kernel modules and sysctl params for Kubernetes networking"
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo "==> 6. Configuring containerd to use the systemd cgroup driver"
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "==> 7. Installing kubeadm, kubelet, kubectl (${K8S_VERSION})"
apt-get install -y apt-transport-https ca-certificates curl gpg
mkdir -p -m 755 /etc/apt/keyrings

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

kubeadm init --pod-network-cidr=10.244.0.0/16

mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

kubectl taint nodes --all node-role.kubernetes.io/control-plane-

kubectl get nodes
kubectl get pods -A

echo ""
echo "==> Done."
echo ""
echo "Docker and Kubernetes tooling (${K8S_VERSION}) are installed."
echo "Log out and back in (or run 'newgrp docker') for ${ORIGINAL_USER} to use Docker without sudo."
echo ""
echo "Next steps:"
# echo "  Control-plane node:"
# echo "    sudo kubeadm init --pod-network-cidr=10.244.0.0/16"
# echo "    mkdir -p \$HOME/.kube"
# echo "    sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
# echo "    sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
# echo "    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
# echo ""
echo "  Worker nodes:"
echo "    Run the 'kubeadm join ...' command printed above, or generate it later on the"
echo "    control-plane node with: kubeadm token create --print-join-command"
