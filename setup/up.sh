#!/usr/bin/env bash
# Everything, in order, on the cluster kubectl points at: Knative, the Restate
# operator, kagent, the Secrets, then Turf and the agent. Each step is safe to
# run again.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
echo "Installing on $(kubectl config current-context)"

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

kubectl apply -k "$here/manifests/kagent"
kubectl wait --for=condition=Accepted --timeout=120s remotemcpserver/turf -n kagent
kubectl wait --for=condition=Ready --timeout=300s agent/turf -n kagent
kubectl get agent turf -n kagent
