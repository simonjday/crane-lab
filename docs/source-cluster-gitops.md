# Could crane-src run Argo CD and Gitea too?

Yes. This lab deliberately doesn't (see README → *Why crane-src has no Argo CD or Gitea*), because the
demo's point is recovering manifests for an app that **isn't** under GitOps. But many real
migrations start from a source that already is. This page covers the realistic variants and what
Crane still contributes in each.

## Variant A: each cluster has its own Argo CD + Gitea

```text
 crane-src: Gitea(src) ─▶ Argo CD(src) ─▶ shop            crane-dst: Gitea(dst) ─▶ Argo CD(dst) ─▶ shop
                 └──────────────── git push --mirror ──────────────▶┘
```

**The migration then is:**
1. Mirror the repo to the destination's Git server (`git push --mirror`), or point Argo CD(dst) at the source repo.
2. Add a **destination overlay**: a Kustomize overlay or Helm values for the new cluster (registry, StorageClass, hostnames).
3. Argo CD(dst) deploys with the stateful workloads at 0 replicas.
4. `crane transfer-pvc` moves the data. This step is unchanged from the lab.
5. A Git commit scales up on the destination, and another removes the app from Argo CD(src).

**What Crane adds here:**
- **Drift detection before you trust Git.** `crane export` from the live source plus `crane transform` gives you what is *actually* running. Diff it against the repo's rendered manifests (`kustomize build`). Anything not in Git (`kubectl edit` hot-fixes that `selfHeal` didn't catch, or resources Argo CD ignores) shows up before the cutover rather than after.
- **Data.** `transfer-pvc` is still the hard part. GitOps moves declarations, not volumes.
- **Out-of-band objects.** Secrets created by hand, operator-generated resources, and anything excluded from the Argo CD app. `crane export` finds them; Git doesn't.

**Cost in this lab:** about 1.5–2 GiB more RAM for a second Argo CD and Gitea, and the demo's
"recover lost manifests" moment becomes a "verify Git matches reality" moment.

## Variant B: one central Argo CD + Git on a management cluster (hub and spoke)

```text
                    ┌─ crane-mgmt ──────────────────┐
                    │ Gitea, Argo CD                │
                    └──────┬────────────────┬───────┘
                           ▼                ▼
                       crane-src         crane-dst      (both registered as Argo CD clusters)
```

This is the most common enterprise shape (and how OpenShift GitOps with RHACM is usually run).

**The migration is a Git change:** move the app's `Application` destination from crane-src to
crane-dst, with replicas at 0 for the stateful parts, then `transfer-pvc`, then scale up. Crane's
role is again data plus drift detection.

**Cost in this lab:** a third kind cluster, about 1.5 GiB more, plus cluster registration
(`argocd cluster add`, or a cluster Secret pointing at the kind node IP on the shared Podman
network).

## Variant C (this lab): source not under GitOps

The source has no trustworthy manifests. Crane **reconstructs** them (export → transform → render),
they're committed, and the destination is onboarded to GitOps as part of the move. Crane does the
most work in this variant, which is why the demo uses it.

## Choosing

| If your audience… | Use |
|---|---|
| has a lot of hand-deployed, drifted workloads, or is starting its GitOps journey | **C** (this lab) |
| already runs GitOps per cluster and asks "why would we need Crane?" | **A**: the drift diff and the data move answer that |
| runs a central GitOps / RHACM hub | **B** |

Variants A and B could be added as optional scripts (`scripts/25-src-gitops.sh` or a third cluster)
without changing the main demo flow.
