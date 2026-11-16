# Turf in kagent

An infrastructure agent in a Kubernetes cluster, running infrastructure outside it.
[kagent](https://kagent.dev) 1.0 runs the agent in a gVisor sandbox; [Turf](https://turf.build)
gives it Terraform's commands as tools: plan, approve, apply, round after round. The cluster is
the control plane: the agent, the approvals, the engine and the state all live in it. What the
agent runs here is a fleet of AWS Lambda functions, and after each rollout it calls every
function to prove the fleet answers.

Turf's engine runs as a Knative service on restate-server, which scales from zero when a round
starts, fans out while it runs and drains back to zero. It holds the AWS key; the agent's
sandbox holds no credential at all. State stays in the cluster, a Secret per stack. Every apply
waits for a person in the kagent UI.

```
kagent UI ── approve? ──► Agent "turf" (Actor, gVisor sandbox, Anthropic model)
                               │  tool call, through Agent Substrate's egress gateway
                               │  (the gateway adds "Authorization: Bearer …")
                               │                          GET, to the fleet's URLs only ──────┐
                               ▼                                                              │
ns turf    turf-mcp-server :3000/mcp ──► restate-server (RestateCluster "turf", operator-managed)
                │                              │  signed requests, via Knative's Route        │
                │                              ▼                                              │
                │                         turf-engine (RestateDeployment, Knative, 0…8 pods)  │
                │                              │  providers run here, with the AWS key        │
                ▼                              ▼                                              ▼
           Secret tfstate-<stack>-turf    AWS: an IAM role, Lambda functions ──────► their public URLs
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
provider plugins run, so it holds the providers' credentials. Here that is one AWS access key,
in the `turf-aws` Secret that only the engine's pods mount, for an IAM user whose policy covers
the fleets' own names and nothing else in the account ([`setup/aws`](setup/aws)): what the
engine may do is what an approved plan may do. Its ServiceAccount is bound to no Role, so it
changes nothing in the cluster it runs in. It is a `RestateDeployment` in Knative mode. The
Restate operator creates a Knative Configuration and a cluster-local Route for it and registers
the Route with restate-server. Knative scales the pods with the work in flight: `minScale: 0`,
`maxScale: 8`, and `target: 4` concurrent requests per pod as the autoscaler's aim. A new Turf
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

**The configuration** comes from the examples image, `ghcr.io/turfbuild/turf-examples`: the
[turfbuild/turf-examples](https://github.com/turfbuild/turf-examples) repository, mounted
read-only at `/turf/examples` in the MCP server's pod and every engine pod. The agent gives
Turf a path inside it,
[`terraform/aws/lambda-fleet`](https://github.com/turfbuild/turf-examples/tree/main/terraform/aws/lambda-fleet):
one execution role, a fleet of Lambda functions, a public URL for each, and a turf action that
verifies the rollout. The agent operates it; it does not edit it. A change is a new image
version.

## Who may talk to whom

Five controls, each independent of the others.

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
   Knative's data path to the engine's pods, and nothing at all to the console. Knative's data
   path is shared, though: Kourier's internal gateway serves every
   Knative service in the cluster, so any pod can reach the engine through its Route, and there
   the signature (control 2) is what refuses it.
4. **Egress, the sandbox → the world.** Agent Substrate's egress gateway denies everything a
   sandbox is not granted. The model and the Agent's MCP servers are granted by being named.
   One more origin is granted here, by an `EgressPolicy` the Agent selects
   ([`egress-policy.yaml`](manifests/kagent/egress-policy.yaml)): the public URLs of Lambda
   functions in the region, `https://*.lambda-url.us-west-2.on.aws`, so the agent can call the
   functions it deployed. It carries no credential. The AWS API is not on the list, and the
   sandbox has no key to use there anyway. The engine's own egress is open: providers reach
   whatever APIs a configuration names.
5. **A token, you → the console.** The console answers no read without the token in
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
curl --http2-prior-knowledge http://turf-engine-v1-4.turf.svc.cluster.local/discover   # 401
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
out instead of a provider. After the fleet is created or patched, the apply pauses, and the
agent fetches every function's URL from its sandbox (the shell, through the egress policy
above), checks each answers with the declared greeting, and reports the result through `apply`
again, which is one more card. A turf action that asks the user something reaches them through
kagent's `ask_user`. The other two bindings are read-only Kubernetes tools, which list the
stacks' Leases, and the OpenTofu Registry's documentation tools, each named.

## Run it

You need Docker, [kind](https://kind.sigs.k8s.io) v0.32 or later, kubectl, Helm 3 or later, the
kagent CLI 1.0.0, an Anthropic API key, and an AWS account. kagent 1.0 needs Kubernetes 1.37.

### The AWS key

The engine acts in AWS as an IAM user made for it, `turf-kagent-engine`, whose policy allows
Lambda functions and IAM roles named `turf-kagent-*` in one region and nothing else.
[`setup/aws`](setup/aws) creates the user, the policy and one access key, with your own AWS
session, and writes the key to `.secrets/`:

```sh
turf -C setup/aws up        # or: tofu -chdir=setup/aws init && tofu -chdir=setup/aws apply
```

On a cluster with a cloud identity, give the engine's ServiceAccount a role with the same policy
instead (EKS Pod Identity) and leave the key out of [`engine.yaml`](manifests/turf/engine.yaml).

### The cluster

```sh
curl -fsSL https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent \
  | bash -s -- --version v1.0.0
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

1. **"Deploy the Lambda fleet as a stack called demo."** The agent loads Turf's deployment
   skill, runs `init` on `/turf/examples/terraform/aws/lambda-fleet`, opens workspace `demo` on
   the kubernetes backend, starts `up` with the stack's variables (two functions named
   `turf-kagent-demo-0` and `-1`), plans, and stops at the approval point. The UI shows an
   approval card for `apply`, with the convergence and the plan digest (9 to add: the execution
   role and its policy attachment, two functions, a URL and a permission for each, and the
   rollout marker), and the agent's message above it links to the round in the console, at its
   approval point with that digest. Engine pods appear in the first terminal as soon as the
   agent opens the workspace. Approve, and the apply pauses at the turf action: the agent
   fetches both function URLs from its sandbox and reports back through `apply`, a second
   card. Approve that too. The engine pods go away a minute or so after the round ends, and
   the functions answer anyone:

   ```sh
   curl https://<id>.lambda-url.us-west-2.on.aws/
   # {"message":"Hello from the cluster.","function":"turf-kagent-demo-0"}
   ```
2. **"Change demo's greeting to 'Patched from the cluster.'"** A second plan, two updates in
   place and the rollout marker, one card; then the agent fetches both URLs again and reports
   the new greeting, a second card.
3. **"What stacks exist, and what is in demo?"** Read-only, no pause: the agent lists the
   stacks' Leases in `turf` with its Kubernetes tools, then reads each stack's state through
   Turf. Ask it for the AWS key, or any Secret, and it cannot: the key is in another namespace,
   its sandbox mounts nothing, and its tool server's role has no access to Secrets.
4. **"Tear down the demo stack."** Another approval card, this time for a destroy plan. Reject
   it with a reason and nothing is applied: the agent cancels the convergence, which frees the
   stack's lock, and repeats your reason back. Ask again and approve, and the fleet is gone.
5. **Four at once.** Open four sessions and ask each for a fleet of its own (`alpha` to
   `delta`). Four convergences run side by side, the engine spreads them over pods
   (`knative.target` and `maxScale` in [`engine.yaml`](manifests/turf/engine.yaml)), and each
   session gets its own cards. The cluster is one pool of provider operations for everyone who
   asks.
6. **Nobody typing.** In the kagent UI, add a Schedule for the agent with a prompt such as
   "Nightly drift check. List the stacks: the lock-tfstate Leases in the turf namespace. For
   each stack, open its workspace, read its outputs, start an up with its variables and plan
   it. If the plan has no changes, cancel the convergence and move on. If a plan has changes,
   say exactly what drifted and what the plan would do, then request the apply so it waits
   for a person's approval in the morning. Finish with one line per stack." Change a
   function's `GREETING` in the AWS console, run the schedule, and the plan that puts it back
   is waiting at its approval point. kagent 1.0.0 cannot take the approval inside a turn a
   schedule started: ask the agent about the stack in a chat, and the card comes up there.

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
- **The engine's AWS key is the demo's**: Lambda functions and IAM roles named `turf-kagent-*`,
  in one region. Widen the policy in [`setup/aws`](setup/aws) to what your configurations
  declare, and prefer a role to a key where the cluster has a cloud identity. A long-lived key
  sits in a Secret in `turf`, which the MCP server's Role can read (the note above): keep the
  state in a namespace of its own to separate them. The engine also runs provider plugins from
  the registry ([`cli-config.yaml`](manifests/turf/cli-config.yaml)) and reaches
  restate-server's admin API for its startup check; a mirror narrows the first.
- **The function URLs are public** (`authorization_type = "NONE"`): anyone who has one can call
  the function, which answers a greeting and nothing else. That is what lets a sandbox with no
  AWS credential check them. A URL behind IAM auth would need a signed request, and so a
  credential the agent is not meant to have; there, let a provider's action do the check in
  the engine.
- **The examples image holds every example**, and the agent can `init` any path in it. What a
  plan can then do is still bounded by the engine's key and a person's approval. Only
  configurations that commit their lock file and write nothing at plan time run from the
  read-only mount.
- **The sandbox has `wget`, not `curl`** (busybox, in kagent's runtime image), and the agent's
  prompt says so. It trusts the egress gateway's CA, which terminates TLS to apply the policy.
- **The agent does not always write the plan out before `apply`.** It is told to, and often
  does, but on kagent 1.0.0 with Claude Sonnet 5.5 it sometimes calls `apply` right after
  `show`. The card then shows only the digest: open the round in the console (the link in the
  agent's message; its Plan tab is the plan), read the plan in the session's `show` result if
  your client shows tool results, or reject the card and ask the agent for the plan.
- **Every authenticated client is one principal.** The token says that a caller may use the
  server, not which caller it is. kagent can mint a per-Actor JWT instead (`actorJwt` on the
  `RemoteMCPServer`), once the server can check one.
- **A rejection's reason reaches the agent** on kagent 1.0.0 (on 1.0.0-rc1 it did not): the
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
- **Versions.** kagent 1.0.0, Knative Serving 1.24.0 with Kourier, the Restate operator
  3.2.0, restate-server 1.8.1, Turf 1.4.0, on kind with Kubernetes 1.37.0.

## Clean up

The fleets are in AWS, not in the cluster: tear the stacks down first (ask the agent, and
approve each destroy), then the cluster, then the engine's IAM user and key.

```sh
kind delete cluster --name turf-kagent
turf -C setup/aws destroy
```

Lambda leaves a CloudWatch log group, `/aws/lambda/<function>`, for every function that was
called; no configuration here declares them, so remove them by hand for a clean account.

## Community

Questions, ideas, or your own take on an infrastructure agent: https://turf.build/discord/. A bug
in Turf goes to https://github.com/turfbuild/turf/issues. Release notes by email:
https://turf.build/newsletter/. Everything else: https://turf.build/community/.

## Trademarks

Terraform is a registered trademark of HashiCorp. AWS and AWS Lambda are trademarks of
Amazon.com, Inc. or its affiliates. Kubernetes is a registered trademark, and
OpenTofu and Knative trademarks, of The Linux Foundation. Anthropic and Claude are trademarks of Anthropic, PBC.
Turf is not affiliated with, endorsed by or sponsored by any of them.
