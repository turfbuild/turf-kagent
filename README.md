# Turf in kagent

An infrastructure agent that lives in the cluster it manages. [kagent](https://kagent.dev) 1.0
runs the agent in a gVisor sandbox; [Turf](https://turf.build) gives it Terraform's commands as
tools: plan, approve, apply, round after round. Turf's engine runs as a Knative service on
restate-server, which scales from zero when a round starts, fans out while it runs and drains
back to zero. State stays in the cluster, a Secret per stack. Every apply waits for a person
in the kagent UI.

```
kagent UI ── approve? ──► Agent "turf" (Actor, gVisor sandbox, Anthropic model)
                               │  tool call, through Agent Substrate's egress gateway
                               │  (the gateway adds "Authorization: Bearer …")
                               ▼
ns turf    turf-mcp-server :3000/mcp ──► restate-server (RestateCluster "turf", operator-managed)
                │                              │  signed requests, via Knative's Route
                │                              ▼
                │                         turf-engine (RestateDeployment, Knative, 0…4 pods)
                │                              │  providers run here
                ▼                              ▼
           Secret tfstate-<stack>-turf    the cluster (or any cloud API)
           Lease  lock-tfstate-<stack>-turf
```

## What runs where

| Namespace | What | Manifest |
|---|---|---|
| `kagent` | the controller and UI; the agent's `Harness`, `AgentTemplate` and `Agent`; a `ModelConfig` for Anthropic; a `RemoteMCPServer` for Turf and one for the OpenTofu Registry | [`manifests/kagent/`](manifests/kagent) |
| `ate-system` | Agent Substrate: the WorkerPool the agent's sandbox runs on, and the egress gateway every connection from the sandbox goes through | `kagent install` |
| `turf` | everything Turf: restate-server, the MCP server, the engine, and the state | [`manifests/turf/`](manifests/turf) |
| `knative-serving`, `kourier-system` | Knative Serving and its Kourier gateway | [`setup/knative.sh`](setup/knative.sh) |
| `restate-operator` | the Restate operator | [`setup/restate-operator.sh`](setup/restate-operator.sh) |

**The MCP server** ([`mcp-server.yaml`](manifests/turf/mcp-server.yaml)) is the agent's toolbox: it
parses the configuration, opens state, and drives the engine through restate-server's ingress.
Its ServiceAccount can read and write Secrets and Leases in `turf`, the OpenTofu kubernetes
backend's two objects, and nothing else.

**The engine** ([`engine.yaml`](manifests/turf/engine.yaml)) plans and applies, and it is where
provider plugins run, so it holds the providers' credentials (here, a ServiceAccount the
demo configuration's kubernetes provider uses in-cluster). It is a `RestateDeployment` in
Knative mode. The Restate operator creates a Knative Configuration and a cluster-local Route
for it and registers the Route with restate-server. Knative scales the pods with the work in
flight: `minScale: 0`, `maxScale: 4`, a new pod past 8 concurrent requests. A new Turf minor
release gets a new `knative.tag`, which the operator registers as a new deployment while the
old one drains what it started.

**restate-server** ([`restate-cluster.yaml`](manifests/turf/restate-cluster.yaml)) is a
`RestateCluster`, one node with its data on a PersistentVolume, provisioned by the operator.

**The configuration** is a configuration image,
`ghcr.io/turfbuild/turf-examples/kubernetes-in-cluster`: a namespace and a ConfigMap, mounted
read-only at `/turf/config` in the MCP server's pod and every engine pod. The agent operates it;
it does not edit it. A change is a new image version.

## Who may talk to whom

Three controls, each independent of the others.

1. **A bearer token, kagent → the MCP server.** The server answers only requests carrying
   `Authorization: Bearer <token>` (`TURF_MCP_AUTH_TOKEN`), and 401 to anything else. kagent
   sends it from the `turf-mcp-auth` Secret named in the `RemoteMCPServer`'s `headersFrom`. The
   agent's sandbox never holds it: the sandbox sends a placeholder, and the egress gateway puts
   the real value in on the way out. The same goes for the Anthropic key.
2. **Request identity, restate-server → the engine.** The RestateCluster signs every request
   it sends the engine with the private key in `turf-engine-identity`
   (`security.requestSigningPrivateKey`); the engine serves nothing that key did not sign
   (`TURF_ENGINE_IDENTITY_KEYS`, the public half).
3. **Network policy.** The operator puts a default-deny policy around restate-server and
   admits only what `security.networkPeers` names: the MCP server on the ingress, the engine
   on the admin API (its startup version check). Ours
   ([`network-policies.yaml`](manifests/turf/network-policies.yaml)) admit kagent's controller
   (tool discovery) and egress gateway to the MCP server, and only Knative's data path to the
   engine. Agent Substrate's own egress policy lets the agent's sandbox reach the model, the
   two MCP servers and nothing else.

Checked from a pod in the cluster with no business there (`kubectl run stray
--image=curlimages/curl …`):

```
curl -m 5 http://restate.turf.svc:8080/restate/health            # timed out
curl -m 5 http://restate.turf.svc:9070/health                    # timed out
curl -m 5 http://turf-mcp-server.turf.svc:3000/mcp               # timed out
curl -m 5 http://<engine pod IP>:8012/                           # timed out
```

and through a port-forward to the MCP server, without the token:

```
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:3000/mcp   # 401
```

## Approvals

The agent's tools come in four bindings ([`agent.yaml`](manifests/kagent/agent.yaml)). The
Turf calls that change nothing on their own run freely: `init`, `open`, `up`, `destroy`,
`plan`, `show` and the rest stop at Turf's plan or at its approval point. The four that change
infrastructure or state, `apply`, `taint`, `untaint` and `delete`, are bound with
`requireApproval: true`, so each one pauses the agent until a person approves it in the kagent
UI. `apply` carries the digest of the plan it applies, so the approval covers exactly the plan
the agent summarized, and nothing else. A turf action that asks the user something reaches them
through kagent's `ask_user`. The other two bindings are kagent's read-only Kubernetes and Helm
tools and the OpenTofu Registry's documentation tools.

## Run it

You need Docker, [kind](https://kind.sigs.k8s.io) v0.32 or later, kubectl, Helm 3 or later, the
kagent CLI 1.0.0-rc1, and an Anthropic API key. kagent 1.0 needs Kubernetes 1.37.

```sh
curl -fsSL https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent \
  | bash -s -- --version v1.0.0-rc1
kind create cluster --name turf-kagent --image kindest/node:v1.37.0
export ANTHROPIC_API_KEY=...
./setup/up.sh
```

[`setup/up.sh`](setup/up.sh) runs the four setup scripts in order (Knative, the Restate operator,
kagent, the Secrets), applies `manifests/turf` and `manifests/kagent`, and waits for the agent.
Every step is safe to run again. The Secrets' source files go in `.secrets/`, which git ignores.

In one terminal, watch the engine. It sits at zero:

```sh
kubectl get pods -n turf -l app=turf-engine -w
```

In another, open the kagent UI and pick the agent `turf`:

```sh
kubectl port-forward -n kagent svc/kagent-ui 8082:8080      # http://localhost:8082
```

1. **"Deploy the mounted configuration as a stack called demo."** The agent loads Turf's
   deployment skill, runs `init` on `/turf/config`, opens workspace `demo` on the kubernetes
   backend, starts `up`, plans, and stops at the approval point. From a run on kind:

   > Plan: 2 to add, 0 to change, 0 to destroy. It creates the namespace `turf-greeting` and
   > the ConfigMap `greeting` in it. Nothing is risky and there are no invocations.

   The UI shows an approval card for `apply`, with the convergence and the plan digest. An
   engine pod appears in the first terminal as soon as the round starts. Approve:

   > I deployed the `demo` stack, and it converged in one round. Apply complete! Resources: 2
   > added, 0 changed, 0 destroyed. […] The state is in the Secret `tfstate-demo-turf` in the
   > `turf` namespace.

   The engine pod goes away a minute or so after the round ends.
2. **"What stacks exist, and what is in demo?"** Read-only, no pause: the agent lists the
   `tfstate-*` Secrets, reads the state, and shows the ConfigMap with its Kubernetes tools.
3. **"Tear down the demo stack."** Another approval card, this time for a destroy plan. Reject
   it and nothing is applied: the agent cancels the convergence and asks what you want instead.
   Ask again and approve, and the namespace is gone.
4. **"Deploy it as a stack called team-a, but ask me which namespace and greeting to use
   first."** The agent asks both questions through `ask_user` before it plans.

Restate's UI shows each round's invocations: `kubectl port-forward -n turf svc/restate 9070`, then
http://localhost:9070.

### Other clients

The agent is an A2A endpoint on the controller, so anything that speaks A2A can drive it. To
answer an approval, a client requests the extension `https://kagent.dev/extensions/hitl/v1`
(header `A2A-Extensions`) and replies with a `tool_approval_response`
([kagent's guide](https://kagent.dev/docs/kagent/1.x/agents/human-in-the-loop/)):

```sh
kubectl port-forward -n kagent svc/kagent-controller 8083:8083
curl -s http://localhost:8083/agents/kagent/turf/.well-known/agent-card.json
```

kagent also serves its Sessions over MCP at `http://localhost:8083/mcp` (`list_sessions`,
`invoke_session`, checkpoints and forks), so Claude Code can talk to the same agent:

```sh
claude mcp add --transport http kagent http://localhost:8083/mcp
```

## Notes

- **One namespace.** The Restate operator runs restate-server in the namespace named after
  the RestateCluster and uses one that already exists as it finds it, so deleting the
  RestateCluster leaves `turf` and the state where they are. The operator's docs advise against
  sharing that namespace with other applications. Here everything in it is Turf's, and each
  NetworkPolicy selects one part's pods.
- **The token crosses the cluster network in cleartext**, from the egress gateway to the MCP
  server over `http://`. Serve the MCP server over TLS (or run a mesh) where that matters.
- **Every authenticated client is one principal.** The token says that a caller may use the
  server, not which caller it is. kagent can mint a per-Actor JWT instead (`actorJwt` on the
  `RemoteMCPServer`), once the server can check one.
- **A rejection's reason does not reach the agent** on kagent 1.0.0-rc1's `kagent` harness:
  it learns that a call was rejected, not why. The system prompt has it cancel the convergence
  and ask.
- **Long applies.** A provider's apply is one request to the engine. restate-server allows a
  request 30 minutes (`abort-timeout`, raised from 10), and the engine's Knative revision
  allows an hour; raise both together for a slower resource. The engine sets nothing of its
  own.
- **Scale from zero has a cost.** Each new engine pod installs providers and modules the first
  time a step lands on it; its caches are its own and go when Knative scales it away.
- **Versions.** kagent 1.0.0-rc1, Knative Serving 1.24.0 with Kourier, the Restate operator
  3.2.0, restate-server 1.8.1, Turf 1.3.0, on kind with Kubernetes 1.37.0.

## Clean up

```sh
kind delete cluster --name turf-kagent
```

## Community

Questions, ideas, or your own take on an infrastructure agent: https://turf.build/discord/. A bug
in Turf goes to https://github.com/turfbuild/turf/issues. Release notes by email:
https://turf.build/newsletter/. Everything else: https://turf.build/community/.

## Trademarks

Terraform is a registered trademark of HashiCorp. Kubernetes is a registered trademark, and
Knative a trademark, of The Linux Foundation. Anthropic and Claude are trademarks of Anthropic, PBC.
Turf is not affiliated with, endorsed by or sponsored by any of them.
