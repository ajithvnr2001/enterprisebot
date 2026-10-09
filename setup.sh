#!/usr/bin/env bash
# One-command setup for demo service (Part 3).
# Idempotent: safe to run twice; second run must exit 0.
# Requires: docker, kind, kubectl, helm.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=demo
NS=demo
RELEASE=demo
IMAGE_REPO=demo-service
IMAGE_TAG=0.1.0
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
INGRESS_NGINX_VERSION="controller-v1.11.3"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}
need docker
need kind
need kubectl
need helm

echo "==> [1/4] ensuring kind cluster '${CLUSTER}' exists"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "kind cluster '${CLUSTER}' already exists, reusing"
else
  echo "creating kind cluster '${CLUSTER}' (with host ports 80/443 for ingress)"
  KIND_CFG="$(mktemp)"
  cat >"${KIND_CFG}" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
  kind create cluster --name "${CLUSTER}" --config "${KIND_CFG}" --wait 60s
  rm -f "${KIND_CFG}"
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

echo "==> [2/4] installing ingress-nginx (${INGRESS_NGINX_VERSION})"
kubectl apply -f "${INGRESS_MANIFEST}"
echo "waiting for ingress-nginx controller to be ready (up to 180s)"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s || {
    echo "ingress-nginx not ready yet, continuing (check with kubectl -n ingress-nginx get pods)"
  }

echo "==> [3/4] building image ${IMAGE} and loading into kind"
docker build -t "${IMAGE}" ./service
kind load docker-image "${IMAGE}" --name "${CLUSTER}"

echo "==> [4/4] installing chart as release '${RELEASE}' into namespace '${NS}'"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --wait --timeout 180s

echo ""
echo "Setup complete."
echo "Verify with:"
echo "  kubectl -n ${NS} get pods"
echo "  kubectl -n ${NS} port-forward svc/${RELEASE}-demo 18080:80 &"
echo "  curl -s http://localhost:18080/ | head"
echo "  curl -s -H 'Host: demo.local' http://127.0.0.1/ | head   # via ingress (needs hostPort 80)"
