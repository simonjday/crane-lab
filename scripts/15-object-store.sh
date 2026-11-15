#!/usr/bin/env bash
# S3 object store for crane transfer-pvc (indirect mode): a container on the shared Podman
# network, outside both clusters. crane-src uploads the PVC to it, crane-dst downloads from it.
# Uses `rclone serve s3` — a multi-arch, single-binary S3 server. Any S3 (MinIO, AWS, Ceph RGW)
# works the same way; only .secrets/rclone.conf changes.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need podman jq

if podman container exists "$OBJ_CONTAINER"; then
  [[ "$(podman inspect "$OBJ_CONTAINER" | jq -r -f "${JQ_DIR}/container-running.jq")" == "true" ]] || podman start "$OBJ_CONTAINER" >/dev/null
  log "object store '${OBJ_CONTAINER}' already exists"
else
  log "starting object store '${OBJ_CONTAINER}' on network '${KIND_NETWORK}' (${OBJ_IMAGE})"
  podman volume exists "${OBJ_CONTAINER}-data" || podman volume create "${OBJ_CONTAINER}-data" >/dev/null
  podman run -d --name "$OBJ_CONTAINER" --network "$KIND_NETWORK" \
    --restart unless-stopped \
    -v "${OBJ_CONTAINER}-data:/data" \
    "$OBJ_IMAGE" \
    serve s3 /data --addr :9000 \
    --auth-key "${OBJ_ACCESS_KEY},${OBJ_SECRET_KEY}" >/dev/null
  # NB: keep the default --vfs-cache-mode off. 'writes'/'full' make freshly uploaded objects
  # unreadable until the cache flushes, which breaks crane's upload-then-download sequence.
fi

# Bucket = top-level directory for rclone serve s3
podman exec "$OBJ_CONTAINER" mkdir -p "/data/${OBJ_BUCKET}"

rm -f "${SECRETS_DIR}/rclone.conf"   # always rewrite on (re)run
RCLONE_CONF_QUIET=1 ensure_rclone_conf
ip=$(objstore_ip)

ok "S3 endpoint http://${ip}:9000  bucket '${OBJ_BUCKET}'"
ok "rclone config: ${SECRETS_DIR}/rclone.conf (gitignored; crane copies it into temporary Secrets)"
