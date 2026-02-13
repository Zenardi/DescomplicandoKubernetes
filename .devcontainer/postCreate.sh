#!/usr/bin/env bash
set -euo pipefail
export DOCKER_API_VERSION=1.43
# Base tools for Oh My Zsh and kind
sudo apt-get update
sudo apt-get install -y --no-install-recommends zsh git curl wget ca-certificates

# Oh My Zsh (unattended)
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# kind (latest release)
if ! command -v kind >/dev/null 2>&1; then
  curl -fsSL https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64 -o /tmp/kind
  chmod +x /tmp/kind
  sudo mv /tmp/kind /usr/local/bin/kind
fi

# kubectl (latest stable)
if ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
  chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
fi

# helm (latest stable)
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Add kubectl alias to zsh config
if [ -f "$HOME/.zshrc" ] && ! grep -q "^alias k='kubectl'$" "$HOME/.zshrc"; then
  echo "alias k='kubectl'" >> "$HOME/.zshrc"
fi

# Enable kubectl autocompletion for zsh (including alias k)
if [ -f "$HOME/.zshrc" ] && ! grep -q "kubectl completion zsh" "$HOME/.zshrc"; then
  cat >> "$HOME/.zshrc" <<'EOF'
source <(kubectl completion zsh)
compdef __start_kubectl k
EOF
fi

# Create a default kind cluster if Docker is available and no cluster exists
if command -v docker >/dev/null 2>&1; then
  if ! kind get clusters >/dev/null 2>&1 || ! kind get clusters | grep -q '^kind$'; then
    kind create cluster --config kind.yaml
  fi
fi
