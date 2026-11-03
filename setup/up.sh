#!/usr/bin/env bash
# Everything, in order, on the cluster kubectl points at: Knative, the Restate
# operator, kagent, the Secrets, then Turf and the agent. Each step is safe to
# run again.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
context=$(kubectl config current-context)
case "$context" in
  kind-*) ;;
  *) [ "${FORCE:-}" = 1 ] || { echo "refusing to install on $context, which is not a kind cluster; set FORCE=1 to go ahead" >&2; exit 1; } ;;
esac
echo "Installing on $context"

"$here/setup/knative.sh"
"$here/setup/restate-operator.sh"
"$here/setup/kagent.sh"
"$here/setup/secrets.sh"

# restate-server first: the engine checks its version at start, and the
# operator registers the engine with it.
kubectl apply -f "$here/manifests/turf/namespace.yaml" -f "$here/manifests/turf/restate-cluster.yaml"
kubectl wait --for=condition=Ready --timeout=300s restatecluster/turf
kubectl rollout status statefulset/restate -n turf --timeout=300s
kubectl apply -k "$here/manifests/turf"
kubectl wait --for=condition=Available --timeout=300s deployment/turf-mcp-server -n turf
kubectl wait --for=condition=Ready --timeout=300s restatedeployment/turf-engine -n turf

# The read-only Kubernetes tool server first, so kagent finds its tools when
# it first connects (it looks again only every few minutes).
kubectl apply -f "$here/manifests/kagent/k8s-tools.yaml"
kubectl rollout status deployment/turf-k8s-reader -n kagent --timeout=300s
kubectl apply -k "$here/manifests/kagent"
for server in turf turf-k8s-reader opentofu-registry; do
  kubectl wait --for=condition=Accepted --timeout=120s "remotemcpserver/$server" -n kagent
done
kubectl wait --for=condition=Ready --timeout=300s agent/turf -n kagent
kubectl get agent turf -n kagent
