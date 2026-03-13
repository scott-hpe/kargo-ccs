#!/bin/bash

set -e

# ============================================================
# Prerequisite checks for macOS
# ============================================================

missing_tools=""

check_tool() {
  tool_name="$1"
  brew_install_hint="$2"

  if ! command -v "$tool_name" >/dev/null 2>&1; then
    echo "❌ '$tool_name' is not installed."
    echo "   Install it with: $brew_install_hint"
    echo ""
    missing_tools="${missing_tools} ${tool_name}"
  else
    version_info=$("$tool_name" version --short 2>/dev/null || "$tool_name" version --client --short 2>/dev/null || "$tool_name" version 2>/dev/null | head -1 || echo "unknown")
    echo "✅ '$tool_name' found: $version_info"
  fi
}

echo "============================================"
echo " Checking required tools..."
echo "============================================"
echo ""

check_tool "kind"    "brew install kind"
check_tool "helm"    "brew install helm"
check_tool "kubectl" "brew install kubectl"
check_tool "argocd"  "brew install argocd"
check_tool "kargo"   "brew install kargo"

echo ""

if [ -n "$missing_tools" ]; then
  echo "============================================"
  echo " ⚠️  Missing tools detected:${missing_tools}"
  echo ""
  echo " You can install all of them at once with:"
  echo "   brew install${missing_tools}"
  echo ""
  echo " If you don't have Homebrew, install it first:"
  echo "   /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  echo "============================================"
  exit 1
fi

echo "============================================"
echo " All required tools are installed. Proceeding..."
echo "============================================"
echo ""

# ============================================================
# Configuration
# ============================================================

set -x

argo_cd_chart_version=9.4.3
argo_rollouts_chart_version=2.40.6
cert_manager_chart_version=1.19.3

# ============================================================
# Create Kind cluster
# ============================================================

kind create cluster \
  --wait 120s \
  --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kargo-quickstart
nodes:
- extraPortMappings:
  - containerPort: 31080 # Argo CD dashboard
    hostPort: 31080
  - containerPort: 31081 # Kargo dashboard
    hostPort: 31081
  - containerPort: 31082 # External webhooks server
    hostPort: 31082
  - containerPort: 32080 # test application instance
    hostPort: 32080
  - containerPort: 32081 # UAT application instance
    hostPort: 32081
  - containerPort: 32082 # prod application instance
    hostPort: 32082
EOF

# ============================================================
# Install cert-manager
# ============================================================

helm install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --version $cert_manager_chart_version \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait

# ============================================================
# Install Argo CD (password: admin)
# ============================================================

helm install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version $argo_cd_chart_version \
  --namespace argocd \
  --create-namespace \
  --set 'configs.secret.argocdServerAdminPassword=$2a$10$5vm8wXaSdbuff0m9l21JdevzXBzJFPCi8sy6OOnpZMAG.fOXL7jvO' \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=31080 \
  --set 'server.extraArgs={--insecure}' \
  --set server.extensions.enabled=true \
  --set 'server.extensions.extensionList[0].name=argo-rollouts' \
  --set 'server.extensions.extensionList[0].env[0].name=EXTENSION_URL' \
  --set 'server.extensions.extensionList[0].env[0].value=https://github.com/argoproj-labs/rollout-extension/releases/download/v0.3.7/extension.tar' \
  --wait

# ============================================================
# Install Argo Rollouts
# ============================================================

helm install argo-rollouts argo-rollouts \
  --repo https://argoproj.github.io/argo-helm \
  --version $argo_rollouts_chart_version \
  --create-namespace \
  --namespace argo-rollouts \
  --wait

# ============================================================
# Install Kargo (password: admin)
# ============================================================

helm install kargo \
  oci://ghcr.io/akuity/kargo-charts/kargo \
  --namespace kargo \
  --create-namespace \
  --set api.service.type=NodePort \
  --set api.service.nodePort=31081 \
  --set 'server.extraArgs={--insecure}' \
  --set api.tls.enabled=false \
  --set api.adminAccount.passwordHash='$2a$10$Zrhhie4vLz5ygtVSaif6o.qN36jgs6vjtMBdM6yrU1FOeiAAMMxOm' \
  --set api.adminAccount.tokenSigningKey=iwishtowashmyirishwristwatch \
  --set externalWebhooksServer.service.type=NodePort \
  --set externalWebhooksServer.service.nodePort=31082 \
  --set externalWebhooksServer.tls.enabled=false \
  --set api.secretManagementEnabled=true \
  --set api.adminAccount.enabled=true \
  --set controller.serviceAccount.clusterWideSecretReadingEnabled=false \
  --set rbac.installClusterRoles=true \
  --set rbac.installClusterRoleBindings=true \
  --set api.rollouts.integrationEnabled=true \
  --set controller.rollouts.integrationEnabled=true \
  --wait

# ============================================================
# Done
# ============================================================

set +x

echo ""
echo "============================================"
echo " 🎉 Kargo quickstart environment is ready!"
echo "============================================"
echo ""
echo " Argo CD UI:  http://localhost:31080  (admin / admin)"
echo " Kargo UI:    http://localhost:31081  (admin / admin)"
echo ""
echo " To tear down: kind delete cluster --name kargo-quickstart"
echo "============================================"
