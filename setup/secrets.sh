#!/usr/bin/env bash
# The four Secrets the stack needs, created from files in .secrets/ (made here
# when missing, and kept so a second run changes nothing):
#   turf/turf-engine-identity  identity.pem (restate-server signs every
#                              request to the engine with it) and public-key
#                              (the engine verifies with it)
#   turf/turf-mcp-auth         token: the MCP server's bearer token
#   kagent/turf-mcp-auth       authorization: "Bearer <token>", the header
#                              value kagent sends
#   turf/turf-console-auth     token: the console's, which a browser gives
#                              once at /login?token= (console.yaml)
# The key pair comes from the engine itself, run once in Docker. Keep
# .secrets/ out of version control (.gitignore does). Safe to run again: with
# no .secrets/ but the Secrets already in the cluster (a fresh clone), it
# copies them back rather than minting new ones, because restate-server, the
# engine and the MCP server read them only at start.
set -euo pipefail
TURF_VERSION=${TURF_VERSION:-v1.4.0}
here=$(cd "$(dirname "$0")/.." && pwd)
dir=${SECRETS_DIR:-$here/.secrets}
mkdir -p "$dir" && chmod 700 "$dir"

# A fresh clone against a cluster that has the Secrets: recover them.
recover() { # namespace secret key file
  [ -s "$dir/$4" ] && return 0
  local v; v=$(kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null) || return 0
  [ -n "$v" ] && (umask 077 && printf '%s' "$v" | base64 -d > "$dir/$4")
}
recover turf turf-engine-identity 'identity\.pem' identity.pem
recover turf turf-engine-identity public-key public-key
recover turf turf-mcp-auth token mcp-token
recover turf turf-console-auth token console-token

if [ ! -s "$dir/identity.pem" ]; then
  docker run --rm --user "$(id -u)" -v "$dir:/k" "ghcr.io/turfbuild/turf-mcp-server:$TURF_VERSION" \
    turf-engine --identity-keygen /k/identity.pem > "$dir/public-key"
fi
if [ ! -s "$dir/mcp-token" ]; then
  # No trailing newline: the server refuses a token with whitespace in it.
  (umask 077 && openssl rand -hex 32 | tr -d '\n' > "$dir/mcp-token")
fi
if [ ! -s "$dir/console-token" ]; then
  (umask 077 && openssl rand -hex 32 | tr -d '\n' > "$dir/console-token")
fi
(umask 077 && printf 'Bearer %s' "$(cat "$dir/mcp-token")" > "$dir/authorization")

kubectl get namespace kagent >/dev/null || { echo "install kagent first (setup/kagent.sh)" >&2; exit 1; }
kubectl get namespace turf >/dev/null 2>&1 || kubectl apply -f "$here/manifests/turf/namespace.yaml"
kubectl -n turf create secret generic turf-engine-identity \
  --from-file=identity.pem="$dir/identity.pem" --from-file=public-key="$dir/public-key" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n turf create secret generic turf-mcp-auth --from-file=token="$dir/mcp-token" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kagent create secret generic turf-mcp-auth --from-file=authorization="$dir/authorization" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n turf create secret generic turf-console-auth --from-file=token="$dir/console-token" \
  --dry-run=client -o yaml | kubectl apply -f -
