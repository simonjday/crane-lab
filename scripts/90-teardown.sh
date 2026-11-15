#!/usr/bin/env bash
# Back to zero: delete both kind clusters, the object store, and everything the demo generated
# locally, so scripts/up.sh + demo/01..06 run exactly as on a first run.
#   - kind clusters crane-src / crane-dst (Gitea, Argo CD and all data go with them)
#   - object store container + volume, .secrets/rclone.conf
#   - migration/ and audit/ (crane artefacts)
#   - gitops/apps/dst/shop.yaml and gitops/workloads/shop/ (published by demo/04)
#   - .lab-git (it only mirrored the Gitea repo that was just deleted; .git is never touched)
# Kept: the Podman machine, Homebrew tools, ~/.local/bin/crane, the platform apps under gitops/,
# and the built rsync-transfer image (PURGE_IMAGE=1 removes it; 35-rsync-image.sh rebuilds it).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kind podman

for c in "$SRC_CLUSTER" "$DST_CLUSTER"; do
  if kind get clusters 2>/dev/null | grep -qx "$c"; then
    log "deleting kind cluster ${c}"
    kind delete cluster --name "$c"
  else
    log "kind cluster ${c} not present"
  fi
done

if podman container exists "$OBJ_CONTAINER"; then
  log "removing object store ${OBJ_CONTAINER}"
  podman rm -f "$OBJ_CONTAINER" >/dev/null
fi
podman volume exists "${OBJ_CONTAINER}-data" && podman volume rm -f "${OBJ_CONTAINER}-data" >/dev/null

log "removing generated files"
rm -rf "$WORK_DIR" "$SECRETS_DIR" "${LAB_ROOT}/audit" "${LAB_ROOT}/demo/audit"
rm -f  "${LAB_ROOT}/gitops/apps/dst/shop.yaml"
rm -rf "${LAB_ROOT}/gitops/workloads/${APP_NS}"
rm -rf "${LAB_ROOT}/.lab-git"

if [[ "${PURGE_IMAGE:-}" == "1" ]] && podman image exists "$RSYNC_IMAGE"; then
  log "removing ${RSYNC_IMAGE}"
  podman rmi -f "$RSYNC_IMAGE" >/dev/null
fi

log "clean. Rebuild with: scripts/up.sh"
