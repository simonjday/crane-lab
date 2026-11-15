# Archived design: direct-mode PVC transfer through ingress-nginx

The first version of this lab moved PVC data with `crane transfer-pvc` **direct mode**, which on plain
Kubernetes needs ingress-nginx. That version worked end to end. It was replaced by Gateway API plus
indirect mode, for the reasons below. This page records how direct mode works, everything it needed
on kind/Podman, the problems we hit, and how to switch back.

## How direct mode works

```text
 crane-src                                   crane-dst
 ┌───────────────────────┐                   ┌───────────────────────────────────────────┐
 │ rsync client pod      │  TLS (stunnel)    │ Ingress  redis-data-shop.<ip>.nip.io       │
 │  mounts source PVC ───┼──────────────────▶│   ingress-nginx (SSL passthrough, :443)    │
 └───────────────────────┘   to node-ip:443  │     └─▶ Service ─▶ rsync daemon pod        │
                                             │           mounts destination PVC           │
                                             └───────────────────────────────────────────┘
```

1. Crane creates, in the destination namespace: a Service, an **Ingress** (class `nginx`, annotation
   `nginx.ingress.kubernetes.io/ssl-passthrough: "true"`, host `<pvc>-<ns>.<subdomain>`), and an
   rsync daemon pod behind a stunnel server.
2. It **waits until the Ingress has an address** in `status.loadBalancer.ingress`. This is the
   pvc-transfer library's endpoint health check.
3. A client pod on the source mounts the PVC and runs rsync through a stunnel client to `<host>:443`.
   ingress-nginx passes the TLS stream straight through (it doesn't terminate it) to the daemon.
4. `--verify` makes rsync checksum every file. Crane then deletes all the temporary resources.

## Why it needs ingress-nginx specifically

In Crane v0.11.1, `--endpoint` accepts only `nginx-ingress` or `route` (OpenShift). The Ingress it
creates relies on the ingress-nginx SSL-passthrough annotation. There is **no Gateway API endpoint**:
no `TLSRoute` with passthrough, so Contour, Envoy Gateway or other Gateway API implementations can't
serve as the transfer endpoint. On OpenShift the `route` endpoint uses the router's passthrough
termination instead.

## What it took on kind + Podman (macOS, Apple Silicon)

Values used (also in [`ingress-nginx-values.yaml`](ingress-nginx-values.yaml)):

```yaml
controller:
  hostPort: { enabled: true, ports: { http: 80, https: 443 } }   # node:443 is the transfer target
  service: { type: ClusterIP }
  nodeSelector: { ingress-ready: "true" }
  tolerations: [{ key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule }]
  publishService: { enabled: false }          # required with publish-status-address (see problems)
  extraArgs:
    enable-ssl-passthrough: "true"            # required by crane
    publish-status-address: localhost         # gives Ingresses an address -> crane's health check passes
  config:
    worker-processes: "2"                     # see PID-limit problem
  admissionWebhooks: { enabled: false }
```

Plus:
- the crane-dst node labelled `ingress-ready=true`
- both clusters on the same Podman network, so crane-src pods reach crane-dst's node IP on :443
- `--subdomain <dst-node-ip>.nip.io`, so `*.10.89.0.4.nip.io` resolves to that node IP from inside pods

The command:

```zsh
crane transfer-pvc --source-context kind-crane-src --destination-context kind-crane-dst \
  --pvc-name redis-data --endpoint nginx-ingress --ingress-class nginx \
  --subdomain "$(kubectl --context kind-crane-dst get nodes -o json | jq -r -f jq/node-internal-ip.jq).nip.io" \
  --source-image localhost/konveyor/rsync-transfer:arm64-local \
  --destination-image localhost/konveyor/rsync-transfer:arm64-local \
  --verify
```

## Problems we hit (and the fixes)

| Problem | Cause | Fix |
|---|---|---|
| Controller in CrashLoopBackOff: `flags --publish-service and --publish-status-address are mutually exclusive` | The chart enables `publishService` by default | `controller.publishService.enabled: false` |
| `transfer-pvc` hung after creating the Ingress | The Ingress never got an address, so crane's endpoint check never passed. The controller had wedged (next row). | Restart a healthy controller; crane continues once `status.loadBalancer` is set |
| nginx workers died with `pthread_create() failed (11: Resource temporarily unavailable)`; controller stuck terminating | Podman's default **PID limit (2048)** on the kind node container. One nginx worker per CPU, each with a thread pool, doubled during a config reload (triggered by crane's new Ingress), next to Argo CD and Gitea on the same node. | `podman update --pids-limit=-1 <node>` (now in `scripts/10-clusters.sh` for both clusters); `worker-processes: "2"` |
| New controller pod `Pending`: "no free host ports" | The old pod was still `Terminating` (5 min grace period) and held hostPorts 80/443 | Force-delete the old pod, or wait it out |
| `quay.io/konveyor/rsync-transfer:latest` won't run on arm64 kind nodes | Image is amd64-only | Build arm64 from source (`scripts/35-rsync-image.sh`); pass `--source-image/--destination-image` |

## Why it was replaced

- **ingress-nginx is retired.** Kubernetes SIG Network ended maintenance in March 2026: no releases, bug fixes or security patches. Images and charts remain available, but adding it to a new design is the wrong lesson.
- **The lab uses Gateway API** for everything else. Running a second controller only for the transfer would be awkward.
- **Indirect mode needs no inbound connectivity at all.** It's closer to real cross-cloud and air-gapped migrations, and it removed the most fragile part of the lab (an Ingress controller on a resource-constrained kind node).

Direct mode is still the better choice when the clusters can reach each other and volumes are large:
one hop instead of two, rsync deltas for a stage-and-cutover flow, and no bucket. MTA 8.3 builds that
stage-and-cutover pattern in. On OpenShift, direct mode with `--endpoint route` needs none of the
ingress-nginx work above.

## Switching this lab back to direct mode

1. `helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --kube-context kind-crane-dst --create-namespace --version 4.15.1 -f docs/ingress-nginx-values.yaml` (with the context namespace set to `ingress-nginx`).
2. Label the dst node: `kubectl --context kind-crane-dst label node crane-dst-control-plane ingress-ready=true`.
3. Replace the `crane transfer-pvc` call in `demo/05-cutover.sh` with the direct-mode command above.
4. Keep Contour for the UIs. The two controllers don't conflict: Envoy is on NodePort 30090, and ingress-nginx is on hostPort 80/443.
