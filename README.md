# crane-lab — migrate a stateful app between two kind clusters with Konveyor Crane

A self-contained lab for an M3 Mac (Podman + kind). It moves a running app **and its persistent data**
from one Kubernetes cluster to another, onboards it to GitOps on the way, and uses **Gateway API**
throughout. There's no Ingress controller anywhere.

```text
                      Podman network "kind"
 ┌─ crane-src (legacy) ───────┐      ┌─ crane-objstore ─┐      ┌─ crane-dst (target) ─────────────────────┐
 │ ns shop                    │      │ S3 endpoint      │      │ Contour + Envoy  (Gateway API)            │
 │  podinfo ×2 (hot-fixed)    │ ───▶ │ rclone serve s3  │ ───▶ │ Gitea  ◀── git push ── your Mac           │
 │  redis ── PVC redis-data   │upload│ bucket           │ down │ Argo CD ── syncs gitops/ ──▶ ns shop      │
 │  NodePort 30080 → :9080    │      │ crane-transfer   │ load │      podinfo, redis, PVC redis-data       │
 └────────────────────────────┘      └──────────────────┘      │ HTTPRoutes → :9090 ; NodePort 30080 → :9081│
          ▲                                                    └───────────────────────────────────────────┘
          └── crane export ──▶ Mac: transform → apply → validate ──▶ git commit ──▶ Gitea ──▶ Argo CD
```

| | |
|---|---|
| **Tool** | [Konveyor Crane](https://github.com/konveyor/crane) `v0.11.1`: export → transform → apply → validate → transfer-pvc. Crane is the upstream lineage of Red Hat MTA's `mta-ops`, and the pipeline is the same. |
| **App** | `podinfo` (web + API) backed by `redis` with a PVC. Orders are written through the app and must survive the move. |
| **Story** | The source app was `kubectl apply`'d and then hot-fixed in place. Crane recovers its real manifests from the live cluster, they're committed to Git, Argo CD deploys them, the data is moved through an object store, and the cutover is a Git commit. |
| **On OpenShift** | The supported equivalent is Red Hat MTA 8.3 `mta-ops`, which succeeds MTC (end of life 31 Dec 2026). Step-by-step mapping, what OpenShift does for you, and when to use which: **[docs/redhat-openshift-comparison.md](docs/redhat-openshift-comparison.md)**. |
| **Networking** | Gateway API (Contour, static provisioning) for the Argo CD and Gitea UIs. PVC data moves with `transfer-pvc` **indirect mode** (S3), so neither cluster needs an inbound endpoint. The original ingress-nginx design is documented in [docs/ingress-nginx-direct-mode.md](docs/ingress-nginx-direct-mode.md). |

## Requirements

- macOS on Apple Silicon, Homebrew, a **rootful** Podman machine with ≥ 10 GiB RAM.
- `kubectl apply` appears in exactly one place, `scripts/30-src-legacy-app.sh`, and that's deliberate: it builds the "legacy" estate the demo migrates away from. Everything on crane-dst arrives through a Helm bootstrap (Gitea, Argo CD) or Git (Contour, routes, the app).
- If another kind lab is running, pause it to free RAM, e.g. `podman stop konveyor-lab-control-plane`.

Host ports (all on `127.0.0.1`; macOS + Podman can't bind < 1024 to a specific address):

| Port | What |
|---|---|
| 9080 | shop on **crane-src** |
| 9081 | shop on **crane-dst** |
| 9090 | Envoy Gateway on crane-dst → `argocd.127.0.0.1.nip.io:9090`, `gitea.127.0.0.1.nip.io:9090` |
| 3001 | Gitea direct (git push) |

The object store listens on `<container-ip>:9000` on the Podman `kind` network only. Clusters reach it there; it isn't published to the Mac.

## Build from scratch

```zsh
git clone https://github.com/simonjday/crane-lab.git && cd crane-lab
./scripts/90-teardown.sh        # only if a previous run exists — returns everything to zero
./scripts/up.sh                 # ~10–15 min
```

| Step | Script | What it does |
|---|---|---|
| 1 | `scripts/00-prereqs.sh` | Homebrew tools; downloads `crane_darwin_arm64` v0.11.1 to `~/.local/bin/crane`; checks the Podman machine is rootful, its RAM, other kind clusters, and free ports. |
| 2 | `scripts/10-clusters.sh` | Creates `crane-src` and `crane-dst` on Podman's `kind` network. Lifts Podman's default 2048 PID limit on both node containers (it otherwise starves busy nodes). Sets both contexts' default namespace to `shop`. |
| 3 | `scripts/15-object-store.sh` | Starts `crane-objstore` (`rclone serve s3`, multi-arch) on the `kind` network, creates bucket `crane-transfer`, and writes `.secrets/rclone.conf` (gitignored). |
| 4 | `scripts/20-dst-platform.sh` | Vendors Contour's static Gateway render into `gitops/platform/contour`. Helm-installs Gitea and pushes this lab to it. Helm-installs Argo CD and the root app, and **Argo CD then deploys Contour and the HTTPRoutes from Git**. Waits until the Argo CD UI answers through the Gateway. |
| 5 | `scripts/30-src-legacy-app.sh` | Deploys the shop on crane-src the "legacy" way, applies drift (`set env`, `scale`, annotate), and seeds 5 orders through the app API. |
| 6 | `scripts/35-rsync-image.sh` | Crane's transfer image on quay is **amd64-only**. This builds `konveyor/rsync-transfer` natively for arm64 from source (its Dockerfile is multi-arch; it bundles rclone with the S3 backend) and side-loads it into both kind nodes. |
| 7 | `scripts/40-preflight.sh` | Proves the transfer path: StorageClass `standard` on both, Gateway programmed, transfer image present, `rclone.conf` present, and **pods on both clusters** reaching the object store. |

`scripts/status.sh [--watch]` shows both clusters, the order lookup on each, what's in the object store, and the Argo CD apps.

## Run the demo

Six scripts, one per migration step. Each prints what it did and what to point at. **[DEMO.md](DEMO.md)** is the presenter's script, with what to show, talking points and likely questions.

| # | Script | What happens | Why it matters |
|---|---|---|---|
| 1 | `01-export.sh` | `crane export` reads every resource in `shop` on crane-src to local disk: the live truth, hot-fixes included, plus runtime noise (`uid`, `status`, `managedFields`). | Read-only. Recovers config nobody has in Git. |
| 2 | `02-transform.sh` | `crane transform` generates Kustomize patches in two stages. `10_KubernetesPlugin` strips noise, whites out Pods/ReplicaSets/Endpoints, downscales Redis to 0 and records the original count. Our `20_DestinationTweaks` changes the UI message for the new cluster. | Every change is a reviewable patch, not an in-place edit. |
| 3 | `03-render-validate.sh` | `crane apply` renders clean manifests locally; `crane validate` checks crane-dst serves every apiVersion/kind. | Catches removed APIs before cutover, not during it. |
| 4 | `04-publish.sh` | Copies the manifests to `gitops/workloads/shop/`, strips controller-owned metadata, adds an Argo CD `Application`, and commits and pushes to Gitea. Argo CD deploys podinfo; Redis stays at 0 with an empty PVC. | GitOps onboarding: Git is the source of truth from now on. |
| 5 | `05-cutover.sh` | Freeze (src Redis → 0), then `crane transfer-pvc` through the object store: an upload pod on src and a download pod on dst. Redis replicas are restored **by a Git commit**, and Argo CD scales it up. | Neither cluster needs an inbound endpoint. The cutover is in Git history. |
| 6 | `06-verify.sh` | Reads the 5 seeded orders through the app on crane-dst and compares them with the seed data. | Proves the data moved intact, end to end. |

```zsh
demo/01-export.sh  demo/02-transform.sh  demo/03-render-validate.sh
demo/04-publish.sh demo/05-cutover.sh    demo/06-verify.sh
demo/reset.sh                         # back to the start, ready to run again
```

## Design decisions

### Gateway API, not Ingress

Gateway API is the current Kubernetes standard for north-south traffic. The Ingress API is still served but feature-frozen, and the most common controller, ingress-nginx, was retired upstream in March 2026. Here, Contour runs in static-provisioning mode: one `Gateway` (`projectcontour/contour`), with Envoy exposed as NodePort 30090 → Mac `:9090`. `HTTPRoute`s in `gitops/platform/routes/` publish the Argo CD and Gitea UIs. Argo CD manages all of it from Git.

One Argo CD wrinkle: in static mode Contour never writes `GatewayClass` status. Argo CD's built-in health check reads that as Progressing forever, so `helm/argocd-values.yaml` overrides `GatewayClass` health: Healthy unless a controller explicitly rejects the class.

### PVC data via an object store (transfer-pvc indirect mode)

`crane transfer-pvc` has two modes:
- **Direct:** rsync over a stunnel TLS tunnel. It needs an inbound endpoint on the destination: an OpenShift Route, or on plain Kubernetes an **ingress-nginx Ingress with SSL passthrough**. Crane has no Gateway API option.
- **Indirect:** an upload pod on the source copies the PVC to S3-compatible storage, then a download pod on the destination restores it. Each cluster only needs **outbound** access to the store.

The lab uses indirect mode, so it needs no Ingress controller. It's also the pattern for clusters with no network path to each other: cross-cloud, separate VPCs, or air-gapped with a staging bucket. `rclone serve s3` stands in for MinIO, AWS S3 or Ceph RGW; only `.secrets/rclone.conf` changes. Data is copied twice (source → store → destination), which doesn't matter at this size. For big volumes, see Crane's split workflow (`--upload-only` / `--download-only`) and `--encrypt`.

The full direct-mode design, every problem we hit with ingress-nginx, and how to switch back are in **[docs/ingress-nginx-direct-mode.md](docs/ingress-nginx-direct-mode.md)**.

### Why crane-src has no Argo CD or Gitea

That's deliberate. crane-src represents the estate Crane exists for: workloads deployed by hand (or by a pipeline nobody trusts), patched live, with no reliable manifests. Crane's first three steps (export, transform, render) **reconstruct** redeployable manifests from what is actually running, drift included. If crane-src were already under GitOps, Git would already be the source of truth, and the migration would mostly be re-pointing Argo CD. The interesting part of the demo would disappear.

Could the source run GitOps too? Yes. It changes the demo's story, and it's a good second scenario. See **[docs/source-cluster-gitops.md](docs/source-cluster-gitops.md)** for the options and what Crane still adds.

## Repo layout

```text
crane-lab/
├── config.env                  # every tunable (ports, versions, names, object store)
├── kind/{src,dst}.yaml         # envsubst templates
├── helm/                       # bootstrap values: gitea, argocd (+ GatewayClass health), argocd-apps
├── legacy-app/shop.yaml        # the "legacy" app (applied imperatively to crane-src)
├── scripts/                    # build: 00 → 10 → 15 → 20 → 30 → 35 → 40; status; teardown
├── demo/                       # run: 01 → 06, reset; seed data; custom stage patch; app template
├── gitops/
│   ├── apps/dst/               # watched by root app: contour-gateway, platform-routes (+ shop from demo/04)
│   ├── platform/contour/       # vendored Contour Gateway render + NodePort / allowedRoutes patches
│   ├── platform/routes/        # HTTPRoutes: argocd, gitea
│   └── workloads/              # demo/04 commits crane's output here
├── docs/                       # Red Hat/OpenShift comparison, ingress-nginx direct mode (archived), source-cluster GitOps variants
├── jq/  yq/                    # every filter, externalised
├── .lab-git/                   # the lab's Gitea-facing repo (separate from your .git) — gitignored
├── migration/                  # crane export/transform/output/validate — gitignored
└── .secrets/                   # rclone.conf — gitignored
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `.secrets/rclone.conf` missing, or "local history doesn't contain Gitea's main" | The lab folder was *replaced* (Finder/Safari unzip → "Replace"), which drops the ignored `.secrets/`, `migration/` and `.lab-git/`. Update with `unzip -o crane-lab.zip` from the parent folder instead. The scripts self-heal either way: `rclone.conf` is regenerated from the running object store, and `ensure_repo` re-attaches the folder to Gitea's history before touching `gitops/`. |
| `bind: permission denied` on port 80/443 | Ports < 1024 can't bind to 127.0.0.1 through Podman on macOS. The lab defaults to ≥ 1024; keep it that way. |
| Argo CD UI not reachable on :9090 after `20-dst-platform.sh` | `kubectl --context kind-crane-dst get gateway,httproute -A` should show Gateway `contour` Programmed and both routes Accepted. If `contour-gateway` is stuck Progressing in Argo CD, check the GatewayClass health override is in `argocd-cm`. |
| Preflight: pods can't reach the object store | Is the container on the `kind` network (`podman inspect crane-objstore`)? Re-run `scripts/15-object-store.sh`; it rewrites `rclone.conf` with the current IP. |
| `transfer-pvc` upload or download pod fails with `exec format error` | The amd64 transfer image is being used. Run `scripts/35-rsync-image.sh` and check `RSYNC_IMAGE` is the `localhost/…:arm64-local` build. |
| `transfer-pvc` fails with `object not found` | The store was started with an rclone VFS cache. Keep the default (`--vfs-cache-mode off`) as in `15-object-store.sh`. |
| `destination PVC … is in use` | Redis on crane-dst isn't at 0 replicas; something scaled it outside Git. |
| Argo CD app `shop` stays `OutOfSync` with every resource running | A controller-owned field from crane-src got into Git. `deployment.kubernetes.io/revision` was the one here: Argo CD applies the source's value and the Deployment controller resets it, forever. `demo/04-publish.sh` strips it with `yq/strip-controller-metadata.yq`; add any other field you find there. |
| Argo CD app `shop` stays `Progressing` after publish | Expected: the PVC is `Pending` until something mounts it (`WaitForFirstConsumer`). It binds during transfer-pvc. |
| git push rejected / `not a git repository` | The scripts re-attach the folder to Gitea's history automatically (`ensure_repo`), with `gitops/` taken from Gitea. |
| Pods fail with `pthread_create() failed` / `Resource temporarily unavailable` | Node PID limit. `podman update --pids-limit=-1 crane-src-control-plane crane-dst-control-plane` (10-clusters.sh does this on create). |

## Notes and limits

- The Gitea repo is public, Argo CD uses the default admin, and the object store has static keys. That's lab-only.
- Crane exports Secrets as-is. This app has none; in a real migration, don't commit them. Use SOPS / External Secrets and add `extra-whiteouts: Secret` to the KubernetesPlugin flags.
- `05-cutover.sh` uses `--keep-cloud-data` so you can show the objects in the store; `demo/reset.sh` clears them.
- Teardown: `scripts/90-teardown.sh` returns the lab to zero. It deletes both clusters, the object store and its volume, `migration/`, `audit/`, `.secrets/`, the published `gitops/` files and `.lab-git/`. Your own `.git` (e.g. a GitHub clone) is never touched. It keeps the Podman machine, the tools and the built transfer image (`PURGE_IMAGE=1` removes the image too).
- Two Git repos share this folder: your `.git` (e.g. the GitHub clone) and `.lab-git/`, the lab's working copy of the in-cluster Gitea repo that Argo CD watches. Files the lab generates (vendored Contour, published `shop` manifests) are ignored by your `.git` and force-added to `.lab-git/` only.

## Licence and credits

MIT, see [LICENSE](LICENSE). Built on [Konveyor Crane](https://github.com/konveyor/crane),
[podinfo](https://github.com/stefanprodan/podinfo), [Contour](https://projectcontour.io),
[Argo CD](https://argo-cd.readthedocs.io), [Gitea](https://gitea.com) and [rclone](https://rclone.org).
Not affiliated with or endorsed by Red Hat. Write-up: [Medium @simonjday](https://medium.com/@simonjday).
