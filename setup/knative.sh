#!/usr/bin/env bash
# Knative Serving with Kourier, the engine's autoscaler. Three settings differ
# from a stock install:
#   - ingress-class: Kourier, the networking layer installed here.
#   - max-revision-timeout-seconds: 3600, so the engine's revision may hold a
#     request (one provider's apply) for up to an hour (engine.yaml).
#   - kubernetes.podspec-volumes-image: enabled, so the engine's pods may mount
#     the configuration image.
# Safe to run again.
set -euo pipefail
KNATIVE_VERSION=${KNATIVE_VERSION:-1.24.0}
base=https://github.com/knative

kubectl apply -f "$base/serving/releases/download/knative-v$KNATIVE_VERSION/serving-crds.yaml"
kubectl wait --for=condition=Established --timeout=120s crd/services.serving.knative.dev crd/configurations.serving.knative.dev
kubectl apply -f "$base/serving/releases/download/knative-v$KNATIVE_VERSION/serving-core.yaml"
kubectl apply -f "$base/net-kourier/releases/download/knative-v$KNATIVE_VERSION/kourier.yaml"

kubectl patch configmap/config-network -n knative-serving --type merge \
  -p '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'
kubectl patch configmap/config-defaults -n knative-serving --type merge \
  -p '{"data":{"max-revision-timeout-seconds":"3600"}}'
kubectl patch configmap/config-features -n knative-serving --type merge \
  -p '{"data":{"kubernetes.podspec-volumes-image":"enabled"}}'

kubectl wait --for=condition=Available --timeout=300s deployment --all -n knative-serving
kubectl wait --for=condition=Available --timeout=300s deployment --all -n kourier-system
