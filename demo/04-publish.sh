#!/usr/bin/env bash
# shellcheck disable=SC2012  # ls output is for display only
# STEP 4 — onboard to GitOps: commit Crane's output + an Argo CD Application, push, let Argo deploy.
# Redis arrives with replicas 0 and an empty PVC; podinfo runs but has no data yet.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
need git yq kubectl jq

src="${WORK_DIR}/output/resources/${APP_NS}"
[[ -d "$src" ]] || die "run demo/03-render-validate.sh first"
dest="${LAB_ROOT}/gitops/workloads/${APP_NS}"
ensure_repo                      # sync gitops/ with Gitea before writing into it

step "copy rendered manifests into gitops/workloads/${APP_NS}/"
rm -rf "$dest" && mkdir -p "$dest"
cp "$src"/*.yaml "$dest"/
# Strip controller-owned metadata exported from crane-src (e.g. deployment.kubernetes.io/revision);
# left in Git it makes Argo CD and the Deployment controller fight — the app never settles to Synced.
for f in "$dest"/*.yaml; do yq -i --from-file "${YQ_DIR}/strip-controller-metadata.yq" "$f"; done
{
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n'
  for f in "$dest"/*.yaml; do
    [[ "$(basename "$f")" == kustomization.yaml ]] || printf '  - %s\n' "$(basename "$f")"
  done
} > "${dest}/kustomization.yaml"
ls -1 "$dest" | sed 's/^/   /'

cp "${LAB_ROOT}/demo/templates/shop-application.yaml" "${LAB_ROOT}/gitops/apps/dst/shop.yaml"
yq -i ".spec.source.repoURL = \"${GITEA_INCLUSTER_URL}\" | .spec.source.path = \"gitops/workloads/${APP_NS}\" | .spec.destination.namespace = \"${APP_NS}\"" \
  "${LAB_ROOT}/gitops/apps/dst/shop.yaml"

step "git commit + push to Gitea"
git_commit_if_changed "migrate(${APP_NS}): manifests recovered from ${SRC_CLUSTER} by crane (redis downscaled for cutover)"
git_push_gitea
git_lab log --oneline -1 | sed 's/^/   /'

step "Argo CD picks it up on ${DST_CLUSTER}"
set_ns "$DST_CTX" argocd
wait_until 180 "Application 'shop' to exist" kdst get applications.argoproj.io shop
set_ns "$DST_CTX" "$APP_NS"
wait_until 300 "podinfo running on ${DST_CLUSTER}" deploy_scaled_ready "$DST_CTX" podinfo
app_status | column -t

step "state on ${DST_CLUSTER}: app is up, data is not"
kdst get deploy,pvc -o json | jq -r -f "${JQ_DIR}/workload-table.jq" | column -t
log "http://127.0.0.1:${DST_APP_PORT}  — new UI message; /cache/order-1001 fails until cutover"
log "next: demo/05-cutover.sh"
