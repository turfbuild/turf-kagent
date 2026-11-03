#!/usr/bin/env bash
# The Restate operator: runs restate-server from a RestateCluster and registers,
# versions and drains the engine from a RestateDeployment. Its CRDs come with
# the chart. Safe to run again.
set -euo pipefail
RESTATE_OPERATOR_VERSION=${RESTATE_OPERATOR_VERSION:-3.2.0}

helm upgrade --install restate-operator oci://ghcr.io/restatedev/restate-operator-helm \
  --version "$RESTATE_OPERATOR_VERSION" \
  --namespace restate-operator --create-namespace \
  --wait --timeout 5m
