# DEMO.md — moving a stateful app between clusters with Konveyor Crane

**Duration:** 20–25 min. **Prereq:** `scripts/up.sh` finished and `scripts/40-preflight.sh` passed.

**The story in one sentence:** an app on an old cluster was deployed by hand and patched live. We
recover its real configuration from the running cluster, put it in Git, deploy it on a new cluster
through Argo CD, move its data through an object store, and cut over with a Git commit. The source
cluster is never changed except for the planned freeze.

**Architecture in one line:** crane-src (legacy, no GitOps) → object store (S3, on the shared Podman
network) → crane-dst (Gitea, Argo CD, Gateway API). See README → *Design decisions* for why there's no
Ingress and no GitOps on the source.

**Screen layout:**
- **Left:** terminal running the `demo/` scripts from the repo root.
- **Right, top:** `scripts/status.sh --watch`.
- **Right, bottom:** browser tabs:
  1. `http://127.0.0.1:9080` (shop on crane-src)
  2. `http://127.0.0.1:9081` (shop on crane-dst, not there yet)
  3. `http://argocd.127.0.0.1.nip.io:9090`
  4. `http://gitea.127.0.0.1.nip.io:9090/gitea_admin/crane-lab`

---

## 0. Set the scene (2 min)

Show tab 1 (red UI, "hot-fixed in prod, running on crane-src") and an order:

```zsh
curl -s http://127.0.0.1:9080/cache/order-1001
```

🎙 *"This is our shop on the old cluster. Orders live in Redis on a persistent volume. It was deployed with `kubectl apply` years ago and patched in production since: someone scaled it, changed config and annotated it during an incident. The YAML in anyone's laptop is wrong. We need to move it to the new cluster with its data, and we want it under GitOps when it lands."*

Show Gitea (tab 4): `gitops/workloads/` is empty. Show Argo CD (tab 3): `root` plus the platform apps (`contour-gateway`, `platform-routes`). Even the UI you're looking at is served by Gateway API from Git.

---

## 1. Export: read what's actually running (3 min)

```zsh
demo/01-export.sh
```

**You should see:**
- crane discovering every resource type in `shop`, then a count by kind (Deployment, Service, PVC, ConfigMap, ReplicaSet, Pod, Endpoints…).
- **The drift captured:** replicas 2, the hot-fix UI message, the `INC-4711` annotation.
- **The noise:** `uid`, `resourceVersion`, `managedFields`, `status`. All of that is cluster-specific.

🎙 *"Export is read-only. Crane asked the API server for everything in the namespace and wrote it to disk: the live truth, including the hot-fixes. It also captured noise that would break or confuse a new cluster. That's the next step."*

Optional: `ls migration/export/resources/shop/`

---

## 2. Transform: clean it, adapt it, review it (4 min)

```zsh
demo/02-transform.sh
```

**You should see:**
- Two stages: `10_KubernetesPlugin` (Crane's built-in clean-up) and `20_DestinationTweaks` (ours).
- One JSON patch per resource, and the op counts.
- **Redis downscaled:** `/spec/replicas → 0` plus `crane.konveyor.io/original-replicas: "1"`.
- **Whiteouts:** the Pods, ReplicaSet, Endpoints, `kube-root-ca.crt` and the default ServiceAccount are dropped. Controllers recreate them on the new cluster.

🎙 *"Transform doesn't edit anything in place. Every change is a Kustomize patch you can review, diff and commit. The built-in plugin strips runtime fields and drops objects the new cluster will generate itself. We asked it to start Redis at zero replicas, because the database mustn't start before its data arrives; it remembers the original count for later. Our own stage changes the UI message for the new cluster. That's where registry rewrites, StorageClass mapping or environment-specific changes go."*

Optional: `cat migration/transform/20_DestinationTweaks/patches/podinfo-destination.patch.yaml`

---

## 3. Render and validate: what will land, and will it fit? (2 min)

```zsh
demo/03-render-validate.sh
```

**You should see:**
- Six clean manifests in `migration/output/resources/shop/`.
- podinfo: **replicas 2 and the incident annotation kept** (the real state), no `uid` or `status`, and the **new UI message**.
- `crane validate`: every apiVersion/kind is served by crane-dst, `Result: PASSED`.

🎙 *"Apply is a misleading name here: it renders, locally. Nothing has touched the new cluster yet. Validate is a preflight: does crane-dst serve every API these manifests use? This catches the classic 'works on the old cluster, that API was removed on the new one' failure before a cutover weekend, not during it."*

---

## 4. Publish to Git: onboard to GitOps (3 min)

```zsh
demo/04-publish.sh
```

**You should see:**
- The manifests copied to `gitops/workloads/shop/` plus a generated `kustomization.yaml`, with controller-owned metadata such as `deployment.kubernetes.io/revision` stripped.
- `gitops/apps/dst/shop.yaml` (Argo CD Application) committed and pushed to Gitea.
- Argo CD creating the `shop` app. podinfo starts on crane-dst; **Redis stays at 0/0; the PVC is `Pending`**.

Show:
- **Gitea (tab 4):** the commit and the files.
- **Argo CD (tab 3):** the `shop` tree, `Progressing` because the PVC waits for a consumer.
- **Tab 2:** the shop on crane-dst with the **green "migrated by Konveyor Crane" message**. Then:
  ```zsh
  curl -s http://127.0.0.1:9081/cache/order-1001   # fails — no data yet
  ```

🎙 *"This is the GitOps onboarding Crane was designed for. The manifests in Git are reconstructed from the running app, not someone's memory. From now on Git is the source of truth for this app on the new cluster. The app is up but has no data, by design."*

---

## 5. Cutover: freeze, move the data, scale up via Git (5 min)

```zsh
demo/05-cutover.sh
```

**You should see:**
1. **Freeze:** Redis on crane-src scaled to 0. The source PVC is unmounted; the destination Redis is confirmed at 0.
2. **`crane transfer-pvc` (indirect mode):**
   - the rclone config is copied into a temporary Secret on each cluster
   - the destination PVC is reused (Argo CD created it)
   - an **upload pod** on crane-src copies the volume to `objstore:crane-transfer/shop/redis-data`
   - a **download pod** on crane-dst restores it
   - the pods appear and disappear in `status.sh`
3. **The object store contents:** Redis's `dump.rdb` and `appendonlydir/…`. They're kept with `--keep-cloud-data` so you can show them.
4. **Scale-up as a commit:** Redis replicas restored from Crane's annotation, committed and pushed.
5. **Argo CD** syncs. Redis becomes ready on crane-dst; the PVC is `Bound`.

🎙 *"The only change to the source cluster in this whole demo is the planned freeze. transfer-pvc ran an upload pod next to the old volume and a download pod next to the new one, with an S3 bucket in between. Neither cluster needed to accept a connection from the other: no Ingress, no firewall change, no VPN. That's the same pattern for cross-cloud moves or an air-gapped site where you carry the bucket across. The data landed in the PVC Argo CD already created, and the scale-up isn't a kubectl command, it's a reviewed commit. The cutover is in the Git history."*

🎙 If asked about direct transfer: *"When clusters can reach each other, Crane can also rsync directly between them over TLS. That's faster for big volumes and supports incremental re-syncs. On OpenShift it uses a Route; on plain Kubernetes it needs ingress-nginx, which has been retired, so this lab uses the object-store path."* (See docs/ingress-nginx-direct-mode.md.)

🎙 Downtime: *"Downtime is the time from freeze to Redis ready: one upload plus one download of the volume. For big volumes you'd pre-stage: upload while live, then freeze and copy a final delta, or use direct rsync, where the delta is all that moves. MTA 8.3 builds that stage-and-cutover pattern in."*

---

## 6. Verify (2 min)

```zsh
demo/06-verify.sh
```

**You should see** all 5 orders read through the app on crane-dst, each matching what was written on crane-src, then `5/5 orders migrated intact`.

Show tab 2: refresh, then open `/cache/order-1003`. Point at Argo CD: `shop` is `Synced / Healthy`.

🎙 *"Same app, same data, new cluster, and now under GitOps. If someone hot-fixes it on the new cluster, Argo CD puts it back."*

Optional proof of that last line:

```zsh
kubectl --context kind-crane-dst scale deploy/podinfo --replicas=5
# watch Argo CD revert it to 2 within ~30s
```

---

## Talking points and likely questions

| Question | Answer |
|---|---|
| How does this relate to Red Hat MTA? | Crane is the Konveyor upstream behind MTA's cluster-migration features. MTA 8.2 added `mta-ops` (same export → transform → apply → validate pipeline, Kustomize stages), and 8.3 added PVC mobility and replaced Migration Toolkit for Containers. Same concepts, Red Hat-supported, OpenShift-focused. Full mapping: docs/redhat-openshift-comparison.md. |
| Why not just back up and restore (Velero)? | Velero restores a snapshot of objects, runtime noise included. Crane produces **clean, reviewable, redeployable manifests** you can put in Git, and transforms them for the target. They complement each other. Velero is better for DR; Crane is better for migration with GitOps onboarding. |
| What about Secrets? | Crane exports them. Don't commit them: whiteout `Secret` in the plugin flags and provide them on the target via SOPS / External Secrets. |
| Does it need cluster-admin? | No. Namespace-level access works; use `crane apply --skip-cluster-scoped`. |
| Clusters with no network path? | That's what we just did: `transfer-pvc --cloud-storage` goes through S3, Azure Blob or GCS (rclone). For a hard air gap, split it: `--upload-only` on one side, carry the bucket across, `--download-only` on the other. Add `--encrypt` for client-side encryption. |
| What would be different on OpenShift? | Direct transfer just works over a Route, with **stage-and-cutover**: sync while live, then a short delta, for less downtime than this lab. `mta-ops` also migrates SCCs, CRDs and RBAC, can convert BuildConfigs (Tech Preview), and generates OpenShift GitOps and Pipelines scaffolding. It's supported, and included with an OpenShift subscription. MTC goes end of life on 31 Dec 2026, and MTA is the replacement. |
| Why no Ingress? | Gateway API is the standard; ingress-nginx is retired. Crane's *direct* transfer on plain Kubernetes still needs ingress-nginx (or a Route on OpenShift), so we use the indirect, object-store path. |
| Why no Argo CD on the old cluster? | Because the scenario is an app that **isn't** under GitOps: Crane reconstructs its manifests. If the source is already GitOps, Crane still finds drift and moves the data (docs/source-cluster-gitops.md). |
| What did Crane miss? | One real gotcha: the export carries `deployment.kubernetes.io/revision` from the source. That annotation belongs to the Deployment controller, so in Git it makes Argo CD and the controller overwrite each other forever and the app never reaches Synced. `04-publish.sh` strips it (`yq/strip-controller-metadata.yq`). Review exports for fields owned by controllers or operators before you commit them. |
| Different storage on the target? | `--dest-storage-class` on transfer-pvc, plus the KubernetesPlugin `pvc-storageclass-map` flag so the manifests match. |
| StatefulSets? | Supported. Transfer each ordinal PVC (`data-<sts>-0`, …). `volumeClaimTemplates` StorageClass changes need a recreate. |
| Limits? | One namespace per run. Volume data is copied at file level, not as a block-level snapshot, so freeze writers first. Operator-managed CRDs are skipped; install the operator on the target. Indirect mode copies twice (source → bucket → destination). |

---

## Recovery during the demo

| Problem | Do this |
|---|---|
| A step fails mid-way | Every crane call uses `--overwrite`, so re-run the same script. |
| transfer-pvc errors | Run `scripts/40-preflight.sh` live. It checks the object store is reachable from pods on both clusters, which is a good teaching moment. Then re-run `demo/05-cutover.sh`; it's idempotent. |
| Everything is on fire | `demo/reset.sh`, then run 01 → 06 straight through. Unattended it takes ~5 minutes. |

## Reset between runs

```zsh
demo/reset.sh
```

This removes `shop` from Git (Argo CD prunes it), deletes the `shop` namespace on crane-dst, brings Redis back on crane-src with its data, and clears `migration/`.
