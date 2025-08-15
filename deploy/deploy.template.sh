#!/bin/bash
# Deploy GitHub Actions Runner Controller with custom runner image
# Template version - configure for your organization

set -e

# Check if GITHUB_TOKEN is set
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: GITHUB_TOKEN environment variable is not set!"
    echo "Please set it using: export GITHUB_TOKEN=your_token_here"
    exit 1
fi

# Kubernetes cluster configuration - set these for your environment
CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-your-cluster-context}"
NAMESPACE="${NAMESPACE:-arc-runners}"
RELEASE_NAME="${RELEASE_NAME:-github-runners}"
VALUES_FILE="dind-values.yaml"

# Switch to the correct Kubernetes context
echo "Switching to Kubernetes context: ${CLUSTER_CONTEXT}"
kubectl config use-context "${CLUSTER_CONTEXT}"
if [ $? -ne 0 ]; then
    echo "Error: Failed to switch to context ${CLUSTER_CONTEXT}"
    echo "Available contexts:"
    kubectl config get-contexts
    exit 1
fi

echo "Deploying GitHub Actions Runner Controller..."
echo "Release: ${RELEASE_NAME}"
echo "Namespace: ${NAMESPACE}"

# Create namespace if it doesn't exist
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Deploy or upgrade the runner scale set
helm upgrade --install "${RELEASE_NAME}" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --set githubConfigSecret.github_token="${GITHUB_TOKEN}" \
  --wait

if [ $? -eq 0 ]; then
    echo ""
    echo "Deployment successful!"
    echo ""
    echo "Checking runner status..."
    sleep 10
    
    kubectl get pods -n "${NAMESPACE}"
    
    echo ""
    echo "To check runner registration:"
    echo "  curl -H \"Authorization: token \$GITHUB_TOKEN\" https://api.github.com/orgs/\${GITHUB_ORG}/actions/runners"
    echo ""
    echo "To use in workflows:"
    echo "  runs-on: ${RELEASE_NAME}"
else
    echo "Deployment failed!"
    exit 1
fi