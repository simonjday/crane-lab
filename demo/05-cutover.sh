#!/usr/bin/env bash
# STEP 5 — cutover: freeze the source, move the volume data, scale up on the destination via Git.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
need crane kubectl git yq jq podman

# Gitea holds the published manifests; make sure this folder has them before touching anything.
ensure_repo
compgen -G "${LAB_ROOT}/gitops/workloads/${APP_NS}/Deployment_*.yaml" >/dev/null \
  || die "gitops/workloads/${APP_NS}/ is empty in this folder — run demo/04-publish.sh (or re-sync from Gitea) first"

set_ns "$SRC_CTX" "$APP_NS"
set_ns "$DST_CTX" "$APP_NS"
store="${OBJ_REMOTE}:${OBJ_BUCKET}"

ensure_rclone_conf               # regenerates it if the lab folder was replaced
podman inspect "$OBJ_CONTAINER" 2>/dev/null | jq -e -f "${JQ_DIR}/container-running.jq" >/dev/null \
  || die "object store ${OBJ_CONTAINER} isn't running — run scripts/15-object-store.sh"

step "1/4 freeze writes on ${SRC_CLUSTER}: scale Redis to 0 (the PVC must be unmounted)"
ksrc scale deploy/redis --replicas=0 >/dev/null
wait_until 120 "source Redis pods to terminate" \
  bash -c "[ -z \"\$(kubectl --context ${SRC_CTX} get pods -l app.kubernetes.io/name=redis -o name)\" ]"
dst_redis=$(kdst get deploy redis -o jsonpath='{.spec.replicas}')
[[ "$dst_redis" == "0" ]] || die "Redis on ${DST_CLUSTER} has ${dst_redis} replicas — the destination PVC must not be in use"
ok "source frozen; destination Redis still at 0"

step "2/4 crane transfer-pvc  ${SRC_CLUSTER}/${PVC_NAME} -> ${store} -> ${DST_CLUSTER}/${PVC_NAME}"
log "indirect mode: an upload pod on ${SRC_CLUSTER} copies the PVC to the object store, a download pod"
log "on ${DST_CLUSTER} restores it. No inbound connectivity, no Ingress — only outbound S3 from each cluster."
crane transfer-pvc \
  --source-context "$SRC_CTX" \
  --destination-context "$DST_CTX" \
  --pvc-name "$PVC_NAME" \
  --cloud-storage "$store" \
  --rclone-config-file "${SECRETS_DIR}/rclone.conf" \
  --source-image "$RSYNC_IMAGE" \
  --keep-cloud-data
kdst get pvc "$PVC_NAME" -o json | jq -r -f "${JQ_DIR}/pvc-line.jq" | sed 's/^/   /'
log "what's in the object store (kept with --keep-cloud-data so you can show it):"
podman exec "$OBJ_CONTAINER" find "/data/${OBJ_BUCKET}" -type f | sed "s|/data/||; s/^/   /"

step "3/4 scale up on ${DST_CLUSTER} — as a Git commit, restoring Crane's recorded replica counts"
changed=0
for f in "${LAB_ROOT}/gitops/workloads/${APP_NS}"/Deployment_*.yaml; do
  orig=$(yq --from-file "${YQ_DIR}/original-replicas.yq" "$f")
  [[ -z "$orig" ]] && continue
  yq -i ".spec.replicas = ${orig} | del(.metadata.annotations[\"crane.konveyor.io/original-replicas\"])" "$f"
  printf '   %-50s replicas -> %s\n' "$(basename "$f")" "$orig"; changed=1
done
(( changed )) || warn "no downscaled workloads found in gitops/workloads/${APP_NS}"
git_commit_if_changed "cutover(${APP_NS}): data transferred, restore replicas on ${DST_CLUSTER}"
git_push_gitea
git_lab log --oneline -1 | sed 's/^/   /'

step "4/4 Argo CD rolls it out"
wait_until 300 "Argo CD to sync the scale-up and Redis ready on ${DST_CLUSTER}" deploy_scaled_ready "$DST_CTX" redis
app_status | column -t

log "next: demo/06-verify.sh"
