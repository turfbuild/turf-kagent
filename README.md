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
| `kagent` | the controller and UI; the WorkerPool the agent's sandbox runs on; the agent's `Harness`, `AgentTemplate` and `Agent`; a `ModelConfig` for Anthropic; `RemoteMCPServer`s for Turf, the OpenTofu Registry and a read-only Kubernetes tool server | [`manifests/kagent/`](manifests/kagent) |
| `ate-system` | Agent Substrate's control plane, and the egress gateway every connection from the sandbox goes through | `kagent install` |
| `turf` | everything Turf: restate-server, the MCP server, the engine, the console, and the state | [`manifests/turf/`](manifests/turf) |
| `knative-serving`, `kourier-system` | Knative Serving and its Kourier gateway | [`setup/knative.sh`](setup/knative.sh) |
| `restate-operator` | the Restate operator | [`setup/restate-operator.sh`](setup/restate-operator.sh) |

**The MCP server** ([`mcp-server.yaml`](manifests/turf/mcp-server.yaml)) is the agent's toolbox: it
parses the configuration, opens state, and drives the engine through restate-server's ingress.
Its ServiceAccount can read and write Secrets and Leases in `turf`, the OpenTofu kubernetes
backend's two objects, and nothing else (that is every Secret in `turf`; see Notes).

**The engine** ([`engine.yaml`](manifests/turf/engine.yaml)) plans and applies, and it is where
provider plugins run, so it holds the providers' credentials. Here that is its
ServiceAccount, which the demo configuration's kubernetes provider uses in-cluster, with a
ClusterRole for exactly what the demo manages (namespaces and ConfigMaps): what the engine may
do is what an approved plan may do. It is a `RestateDeployment` in Knative mode. The Restate
operator creates a Knative Configuration and a cluster-local Route for it and registers the
Route with restate-server. Knative scales the pods with the work in flight: `minScale: 0`,
`maxScale: 4`, and `target: 8` concurrent requests per pod as the autoscaler's aim. A new Turf
minor release gets a new `knative.tag`, which the operator registers as a new deployment while
the old one finishes what it started.

**The console** ([`console.yaml`](manifests/turf/console.yaml)) is Turf's read-only web view of
every workspace: its convergences, each round's plan, approval point and apply, who approved
what, and the lanes as they ran. It is `turf-ui` from the same image, reading restate-server's
ingress and nothing else. Nothing in the cluster can reach it; you port-forward to it and sign
in once with its token. Every result the MCP server hands the agent carries a `console_url`
for its round (`TURF_CONSOLE_URL`), so the agent's message with a plan links to the round at its
approval point.

**restate-server** ([`restate-cluster.yaml`](manifests/turf/restate-cluster.yaml)) is a
`RestateCluster`, one node with its data on a PersistentVolume, provisioned by the operator.

**The configuration** is a configuration image,
`ghcr.io/turfbuild/turf-examples/kubernetes-in-cluster`: a namespace and a ConfigMap, mounted
read-only at `/turf/config` in the MCP server's pod and every engine pod. The agent operates it;
it does not edit it. A change is a new image version.

## Who may talk to whom

Four controls, each independent of the others.

1. **A bearer token, kagent → the MCP server.** The server answers only requests carrying
   `Authorization: Bearer <token>` (`TURF_MCP_AUTH_TOKEN`), and 401 to anything else. kagent
   sends it from the `turf-mcp-auth` Secret named in the `RemoteMCPServer`'s `headersFrom`. The
   agent's sandbox never holds it: the sandbox sends a placeholder, and the egress gateway puts
   the real value in on the way out. The same goes for the Anthropic key. Nor can the agent
   fetch them: its Kubernetes tools come from a tool server of its own
   ([`k8s-tools.yaml`](manifests/kagent/k8s-tools.yaml)), read-only, whose ServiceAccount has
   Kubernetes' `view` role, which leaves Secrets out. (kagent's built-in `kagent-tool-server`
   runs as cluster-admin, so this agent does not bind it.)
2. **Request identity, restate-server → the engine.** The RestateCluster signs every request
   it sends the engine with the private key in `turf-engine-identity`
   (`security.requestSigningPrivateKey`); the engine serves nothing that key did not sign
   (`TURF_ENGINE_IDENTITY_KEYS`, the public half).
3. **Network policy.** The operator puts a default-deny policy around restate-server and
   admits only what `security.networkPeers` names: the MCP server and the console on the
   ingress, the engine on the admin API (its startup version check). Ours
   ([`network-policies.yaml`](manifests/turf/network-policies.yaml)) admit kagent's controller
   (tool discovery) and egress gateway to the MCP server and the Kubernetes tool server, only
   Knative's data path to the engine's pods, and nothing at all to the console. Agent
   Substrate's own egress policy lets the agent's sandbox reach the model, its MCP servers and
   nothing else. Knative's data path is shared, though: Kourier's internal gateway serves every
   Knative service in the cluster, so any pod can reach the engine through its Route, and there
   the signature (control 2) is what refuses it.
4. **A token, you → the console.** The console answers no read without the token in
   `turf-console-auth` (`TURF_CONSOLE_AUTH_TOKEN`): a browser gives it once at
   `/login?token=…` and keeps a cookie, a program sends it as a bearer header, and only
   `/api/health` answers without it. A port-forward is the only way to the pod, and the token
   is what its reader then has to show. The links Turf hands the agent never carry it.

Checked from a pod in the cluster with no business there (`kubectl run stray
--image=curlimages/curl …`):

```
curl -m 5 http://restate.turf.svc:8080/restate/health                   # timed out
curl -m 5 http://restate.turf.svc:9070/health                           # timed out
curl -m 5 http://turf-mcp-server.turf.svc:3000/mcp                      # timed out
curl -m 5 http://turf-k8s-reader.kagent.svc:8084/mcp                    # timed out
curl -m 5 http://turf-console.turf.svc:8873/api/health                  # timed out
curl -m 5 http://<engine pod IP>:8012/                                  # timed out
curl --http2-prior-knowledge http://turf-engine-v1-3.turf.svc.cluster.local/discover   # 401
```

The last one goes through Kourier and reaches the engine, which refuses it: restate-server did
not sign it. The engine answers one path unsigned, `/health`.

and through a port-forward to the MCP server, without the token:

```
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:3000/mcp   # 401
```

and to the console, without its cookie:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8873/config.json       # 401
```

## Approvals

The agent's tools come in four bindings ([`agent.yaml`](manifests/kagent/agent.yaml)). The
Turf calls that change nothing on their own run freely: `init`, `open`, `up`, `destroy`,
`plan`, `show` and the rest stop at Turf's plan or at its approval point. The four that change
infrastructure or state, `apply`, `taint`, `untaint` and `delete`, are bound with
`requireApproval: true`, so each one pauses the agent until a person approves it in the kagent
UI. `apply` carries the digest of the plan it applies, so the approval covers exactly that plan,
and nothing else. The card shows the call's arguments, the convergence and the digest; the plan
itself is the `show` call just above it in the session (see Notes).

The configuration also declares a **turf action**: a step of the apply that the agent carries
out instead of a provider. After the Job is created, the apply pauses, and the agent watches the
Job with its read-only Kubernetes tools and reports its result through `apply` again, which is
one more card. A turf action that asks the user something reaches them through kagent's
`ask_user`. The other two bindings are read-only Kubernetes tools and the OpenTofu Registry's
documentation tools, each named.

## Run it

You need Docker, [kind](https://kind.sigs.k8s.io) v0.32 or later, kubectl, Helm 3 or later, the
kagent CLI 1.0.0-rc3, and an Anthropic API key. kagent 1.0 needs Kubernetes 1.37.

```sh
curl -fsSL https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent \
  | bash -s -- --version v1.0.0-rc3
kind create cluster --name turf-kagent --image kindest/node:v1.37.0
export ANTHROPIC_API_KEY=...
./setup/up.sh
```

[`setup/up.sh`](setup/up.sh) runs the four setup scripts in order (Knative, the Restate operator,
kagent, the Secrets), applies `manifests/turf` and `manifests/kagent`, and waits for the agent.
Every step is safe to run again, and it refuses a kubectl context that is not a kind cluster
unless you set `FORCE=1`. The Secrets' source files go in `.secrets/`, which git ignores; on a
fresh clone against a cluster that already has the Secrets, `setup/secrets.sh` copies them back
instead of minting new ones.

In one terminal, watch the engine. It sits at zero:

```sh
kubectl get pods -n turf -l app=turf-engine -w
```

In another, open the kagent UI and pick the agent `turf`:

```sh
kubectl port-forward -n kagent svc/kagent-ui 8082:8080      # http://localhost:8082
```

And in a third, the Turf console, signed in once with its token:

```sh
kubectl port-forward -n turf svc/turf-console 8873
open "http://localhost:8873/login?token=$(cat .secrets/console-token)"
```

1. **"Deploy the mounted configuration as a stack called demo."** The agent loads Turf's
   deployment skill, runs `init` on `/turf/config`, opens workspace `demo` on the kubernetes
   backend, starts `up`, plans, and stops at the approval point. The UI shows an approval card
   for `apply`, with the convergence and the plan digest (3 to add: the namespace, the
   ConfigMap and the Job). Engine pods appear in the first terminal as soon as the agent opens
   the workspace. Approve, and the apply pauses at the turf action: the agent checks the Job
   and its pod with its Kubernetes tools and reports back through `apply`, a second card.
   Approve that too. From a run on kind:

   > The `demo` stack is deployed and converged. Apply complete! Resources: 3 added, 0 changed,
   > 0 destroyed. […] **Turf action:** the configuration has a step that waits for the Job, and
   > the apply paused there. I checked the Job myself. It had `succeeded: 1` and condition
   > `Complete`, and its pod `greet-tb9jv` was `Completed`. The pod's log line was `Hello from
   > a configuration image.`, and I reported that back as a success.

   The UI shows an approval card for `apply`, with the convergence and the plan digest, and
   the agent's message above it links to the round in the console, at its approval point with
   that digest. An engine pod appears in the first terminal as soon as the agent opens the
   workspace. Approve:

   > I deployed the `demo` stack, and it converged in one round. Apply complete! Resources: 2
   > added, 0 changed, 0 destroyed. […] The state is in the Secret `tfstate-demo-turf` in the
   > `turf` namespace.

   The engine pods go away a minute or so after the round ends.
2. **"What stacks exist, and what is in demo?"** Read-only, no pause: the agent lists the
   stacks' Leases in `turf` with its Kubernetes tools, then reads each stack's state through
   Turf. Ask it for a Secret and it cannot: the tool server's role has no access to them.
3. **"Tear down the demo stack."** Another approval card, this time for a destroy plan. Reject
   it with a reason and nothing is applied: the agent cancels the convergence, which frees the
   stack's lock, and repeats your reason back. Ask again and approve, and the namespace is gone.
4. **"Deploy it as a stack called team-a, but ask me which namespace and greeting to use
   first."** The agent asks both questions through `ask_user` before it plans.
5. **Four at once.** Open four sessions and ask each for its own stack (`team-a` to `team-d`,
   each with `namespace` set to its name). Four convergences run side by side, the engine
   spreads them over pods (`knative.target` and `maxScale` in
   [`engine.yaml`](manifests/turf/engine.yaml)), and each session gets its own cards. The
   cluster is one pool of provider operations for everyone who asks.

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
- **The MCP server can read every Secret in `turf`**, the engine's signing key and its own
  token included, because the state backend needs Secrets there and Kubernetes RBAC cannot
  scope `create` and `list` by name. Everything Turf shares one namespace here; to narrow it,
  keep the state in a namespace of its own (`backend_config.namespace` in the agent's prompt)
  and move the Role there.
- **The engine's ClusterRole is the demo's**: namespaces, ConfigMaps and Jobs. Widen it to what your
  configurations declare. The engine also runs provider plugins from the registry
  ([`cli-config.yaml`](manifests/turf/cli-config.yaml)) and reaches restate-server's admin API
  for its startup check; a mirror narrows the first.
- **The agent does not always write the plan out before `apply`.** It is told to, and often
  does, but on kagent 1.0.0-rc3 with Claude Sonnet 5.5 it sometimes calls `apply` right after
  `show`. The card then shows only the digest: open the round in the console (the link in the
  agent's message; its Plan tab is the plan), read the plan in the session's `show` result if
  your client shows tool results, or reject the card and ask the agent for the plan.
- **Every authenticated client is one principal.** The token says that a caller may use the
  server, not which caller it is. kagent can mint a per-Actor JWT instead (`actorJwt` on the
  `RemoteMCPServer`), once the server can check one.
- **A rejection's reason reaches the agent** on kagent 1.0.0-rc3 (on rc1 it did not): the
  agent cancels the convergence, which frees the stack's lock, and answers with the reason.
- **Session snapshots** go to the object store kagent installs (`snapshotPolicy` in
  [`harness.yaml`](manifests/kagent/harness.yaml)). They hold what the session holds: the
  plans and state the agent read, not the token or the model key.
- **Long applies.** A provider's apply is one request to the engine. restate-server allows a
  request 30 minutes (`abort-timeout`, raised from 10), and the engine's Knative revision
  allows an hour; raise both together for a slower resource. The engine sets nothing of its
  own.
- **Scale from zero has a cost.** Each new engine pod installs providers and modules the first
  time a step lands on it; its caches are its own and go when Knative scales it away.
- **Keep `knative.tag` and the image together.** A new tag is a new Restate deployment; the
  same tag with a new image updates in place, which Restate allows only for a change compatible
  with invocations in flight.
- **Versions.** kagent 1.0.0-rc3, Knative Serving 1.24.0 with Kourier, the Restate operator
  3.2.0, restate-server 1.8.1, Turf 1.4.0, on kind with Kubernetes 1.37.0.

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
OpenTofu and Knative trademarks, of The Linux Foundation. Anthropic and Claude are trademarks of Anthropic, PBC.
Turf is not affiliated with, endorsed by or sponsored by any of them.
