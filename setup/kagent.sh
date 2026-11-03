#!/usr/bin/env bash
# kagent 1.0 with Anthropic as its model provider: the controller, the UI,
# Agent Substrate (gVisor sandboxes and the egress gateway) and a bundled
# PostgreSQL. The minimal profile installs no sample agents. Needs the kagent
# CLI of the same release on PATH and ANTHROPIC_API_KEY in the environment;
# the CLI stores the key in the kagent-anthropic Secret. Safe to run again.
set -euo pipefail
KAGENT_VERSION=${KAGENT_VERSION:-1.0.0-rc1}
here=$(cd "$(dirname "$0")/.." && pwd)

: "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY}"
have=$(kagent version 2>/dev/null | sed -n 's/.*"kagent_version":"\([^"]*\)".*/\1/p' || true)
if [ "$have" != "$KAGENT_VERSION" ]; then
  echo "kagent CLI $KAGENT_VERSION is required (found: ${have:-none}). Install it with:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash -s -- --version v$KAGENT_VERSION" >&2
  exit 1
fi

# The CLI reads values files relative to where it runs.
cd "$here/values"
kagent --config kagent-config.yaml install --namespace kagent --profile minimal --timeout 20m
kubectl rollout status deployment/kagent-controller -n kagent --timeout=300s
kubectl get workerpools -n kagent
