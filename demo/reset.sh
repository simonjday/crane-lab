#!/usr/bin/env bash
# Reset to the pre-demo state so you can run 01→06 again:
#   - remove the shop app from Git (Argo prunes it from crane-dst)
#   - bring Redis back on crane-src
#   - delete local crane artefacts and the objects left in the store (--keep-cloud-data)
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
need git kubectl podman

step "remove shop from Git"
ensure_repo                      # sync gitops/ with Gitea first, then remove
rm -f "${LAB_ROOT}/gitops/apps/dst/shop.yaml"
rm -rf "${LAB_ROOT}/gitops/workloads/${APP_NS}"
git_commit_if_changed "reset: remove ${APP_NS} from ${DST_CLUSTER}"
git_push_gitea

set_ns "$DST_CTX" argocd
wait_until 180 "Argo CD to prune Application 'shop'" bash -c "! kubectl --context ${DST_CTX} get applications.argoproj.io shop"
set_ns "$DST_CTX" "$APP_NS"
# CreateNamespace=true namespaces are not pruned by Argo CD; remove it so the next run starts clean.
kdst delete namespace "$APP_NS" --ignore-not-found --wait=true >/dev/null
ok "${DST_CLUSTER} clean"

step "restore Redis on ${SRC_CLUSTER}"
set_ns "$SRC_CTX" "$APP_NS"
ksrc scale deploy/redis --replicas=1 >/dev/null
ksrc rollout status deploy/redis --timeout=180s

rm -rf "$WORK_DIR"
podman exec "$OBJ_CONTAINER" sh -c "rm -rf /data/${OBJ_BUCKET}/* && mkdir -p /data/${OBJ_BUCKET}" 2>/dev/null || true
ok "local artefacts and transferred objects removed"
log "ready to run demo/01-export.sh again"
