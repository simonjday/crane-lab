# This lab vs. the Red Hat version on OpenShift

This lab runs **upstream Konveyor Crane** on two kind clusters. Red Hat ships the same lineage as
**`mta-ops`, part of the Migration Toolkit for Applications (MTA)**, for OpenShift. This page maps
one to the other, so you can tell an audience what they'd get on OpenShift and what the lab had to
build by hand.

> Status as of November 2026. MTA 8.3 is GA. Migration Toolkit for Containers (MTC) reaches end of life
> on **31 December 2026**, and MTA is its official replacement. Check the sources at the end before you quote versions.

## Lineage in one paragraph

Konveyor is the upstream community; MTA is Red Hat's supported downstream. MTA was mostly known for
**application** analysis: the Hub UI, `kantra`, rules, and Developer Lightspeed. **MTA 8.2** added
`mta-ops`, a standalone CLI that runs the same export → transform → apply → validate pipeline as
Crane, initially for **stateless** workloads between OpenShift 4.x clusters. **MTA 8.3** added
**PVC data migration** and became the transition path from MTC. It also added asset generators
that produce GitOps and pipeline scaffolding.

## Step-by-step mapping

| Lab step | What the lab does (upstream, any Kubernetes) | Red Hat on OpenShift (MTA 8.3) |
|---|---|---|
| 01 Export | `crane export` from the live namespace | `mta-ops` export. The same read-only, local-disk approach: nothing is written to the source cluster. |
| 02 Transform | Kustomize stages: `10_KubernetesPlugin` plus a custom `20_DestinationTweaks` stage | The same Kustomize-overlay pipeline. Also migrates **cluster-scoped dependencies** (RBAC, CRDs, **SCCs**), and can convert **BuildConfig → OpenShift Builds** (Technology Preview). |
| 03 Render + validate | `crane apply` (local render) and `crane validate` (API preflight) | The same: a read-only preflight that checks API compatibility on the target. |
| 04 Publish to Git | Our scripts commit to Gitea; a hand-written Argo CD `Application` | **OpenShift GitOps generator** (Helm-based) emits an Argo CD `Application` with automated sync, prune and self-heal. A **Pipelines generator** emits Tekton, and a **Java Service generator** emits manifests plus a Containerfile. |
| 05 Data | `crane transfer-pvc` **indirect** mode via an S3 bucket (`rclone serve s3` stand-in) | **Indirect PVC migration via S3**, positioned for air-gapped and cross-cloud use and validated for AWS S3, with client-side encryption. Or **direct** TLS transfer with **stage-and-cutover**: sync while live, then a short delta at cutover. |
| 05 Direct-mode endpoint | Needed **ingress-nginx with SSL passthrough** on plain Kubernetes, so the lab avoids it ([why](ingress-nginx-direct-mode.md)) | On OpenShift the endpoint is a **Route**: built in, no extra controller. Upstream Crane supports Route endpoints, and MTC's direct volume migration worked the same way (rsync over a Route, with stunnel). Check the `mta-ops` docs for its exact endpoint options. |
| 05 Cutover | Scale-up as a Git commit, then Argo CD syncs | The same pattern with OpenShift GitOps (Argo CD). |
| 06 Verify | App-level checks via the API | Your own tests. MTA doesn't verify application data. |
| — | — | **Intra-cluster StorageClass conversion**: clone PVC data to a new class and rebind, without manifest edits. |

## What OpenShift gives you that the lab had to build

| Lab workaround | Why it was needed | On OpenShift |
|---|---|---|
| Build `rsync-transfer` for arm64 from source (`35-rsync-image.sh`) | Upstream image on quay is amd64-only; the lab runs on Apple Silicon | Supported images for supported platforms |
| `rclone serve s3` on the Podman network (`15-object-store.sh`) | Indirect mode needs S3; no cloud bucket in a laptop lab | Any S3 (AWS S3 is the validated one), or ODF / NooBaa object storage in-cluster |
| No ingress-nginx; indirect mode only | Crane direct mode needs ingress-nginx SSL passthrough on vanilla Kubernetes; ingress-nginx was retired in March 2026 | Routes: direct mode works out of the box, including stage-and-cutover |
| Argo CD `GatewayClass` health override | Contour static mode never writes `GatewayClass` status | Not needed: the OpenShift router and Routes, or the OpenShift Gateway API implementation |
| Strip `deployment.kubernetes.io/revision` before committing (`yq/strip-controller-metadata.yq`) | Exported controller-owned annotation fights Argo CD forever | Same risk: review exports for controller- and operator-owned fields regardless of tool |
| Podman PID limit, ports ≥ 1024 | kind on rootful Podman on macOS | Not applicable |
| Self-rolled Gitea + Argo CD bootstrap | Lab needs a Git server and GitOps controller | OpenShift GitOps operator; your enterprise Git (GitLab, GitHub, Bitbucket) |

## Beyond cluster-to-cluster (what MTA adds around it)

- **Application analysis and assessment:** the MTA Hub UI, `kantra` CLI and IDE plugins, with rules for Java EE, Spring Boot → Quarkus, .NET and more. That decides *which* apps to move and what code changes they need. This lab only moves an already-containerised app.
- **Developer Lightspeed for MTA:** AI-assisted remediation of analysis findings. Check your entitlement before you promise it to a customer.
- **Agentic migration factory (Developer Preview in 8.3):** multi-agent code-migration workflows running in sandboxes on OpenShift, with Git as the hand-off between stages.
- **Asset generators:** onboard a migrated app with pipeline and GitOps scaffolding on day one.

## Support and licensing

| | This lab | Red Hat |
|---|---|---|
| Tool | Konveyor Crane `v0.11.1` (community, Apache 2.0) | MTA `mta-ops` (supported) |
| Platform | Any conformant Kubernetes (kind here) | OpenShift 4.x |
| Cost | Free | MTA is included with an OpenShift or Red Hat Application Foundations subscription |
| Support | GitHub issues | Red Hat support; Technology and Developer Preview features excluded |
| Predecessor | — | MTC (end of life 31 Dec 2026) |

## Choosing

- **On OpenShift with a subscription:** use MTA `mta-ops`. Prefer direct, stage-and-cutover transfer over Routes when clusters can reach each other; it gives the shortest downtime. Use S3 indirect mode for air-gapped or cross-cloud moves.
- **On vanilla Kubernetes (EKS, AKS, GKE, kind, k3s):** upstream Crane, as in this lab. Indirect mode avoids the ingress-nginx dependency. Budget for building your own images if you're not on amd64.
- **Backup and DR, not migration:** OADP / Velero. They restore snapshots of objects rather than producing clean, reviewable manifests for Git.
- **Either way:** the method this lab demonstrates carries over unchanged: reconstruct from the live cluster → review as Kustomize patches → commit → let GitOps deploy → move the data → cut over with a commit.

## Sources

- [MTA 8.3: agentic code modernization, PVC mobility, and out-of-the-box generators](https://developers.redhat.com/articles/2026/10/08/migration-toolkit-applications-8-3-agentic-code-modernization) — Red Hat Developer, Oct 2026
- [MTA 8.2: Modernize your applications and clusters](https://developers.redhat.com/articles/2026/07/22/migration-toolkit-applications-8-2-modernize-your-applications) — Red Hat Developer, Jul 2026 (`mta-ops` introduced)
- [MTA 8.3 documentation](https://docs.redhat.com/en/documentation/migration_toolkit_for_applications/8.3) — includes "Migrating workloads by using the mta-ops CLI"
- [MTC documentation (OpenShift 4.15)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.15/html/migration_toolkit_for_containers) — end-of-life notice, 31 Dec 2026
- [FAQ about the Migration Toolkit for Containers sunset](https://access.redhat.com/articles/7137482)
- [MTC advanced migration options](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/migration_toolkit_for_containers/advanced-migration-options-mtc) — direct volume migration is rsync over an OpenShift Route, using stunnel
- [Getting started with MTA](https://developers.redhat.com/products/mta/getting-started) — included with OpenShift / Application Foundations subscriptions
- [Konveyor Crane](https://github.com/konveyor/crane)
