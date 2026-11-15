#!/usr/bin/env bash
# quay.io/konveyor/rsync-transfer is published amd64-only. On Apple Silicon, build it natively
# from source (its Dockerfile is TARGETARCH-aware) and side-load it into both kind nodes.
# crane's transfer pods don't set imagePullPolicy, so a non-:latest tag means IfNotPresent → no pull.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need podman kind git

if [[ "$RSYNC_IMAGE" != localhost/* ]]; then
  log "RSYNC_IMAGE=${RSYNC_IMAGE} is a registry image — nothing to build"
  exit 0
fi

case "$(uname -m)" in arm64|aarch64) platform=linux/arm64 ;; *) platform=linux/amd64 ;; esac

if podman image exists "$RSYNC_IMAGE" && [[ "${REBUILD:-}" != "1" ]]; then
  log "${RSYNC_IMAGE} already built (REBUILD=1 to force)"
else
  src=$(mktemp -d)
  trap 'rm -rf "$src"' EXIT
  log "cloning konveyor/rsync-transfer @ ${RSYNC_TRANSFER_REF:-default branch}"
  git clone -q https://github.com/konveyor/rsync-transfer.git "$src"
  [[ -n "$RSYNC_TRANSFER_REF" ]] && git -C "$src" checkout -q "$RSYNC_TRANSFER_REF"
  log "source commit $(git -C "$src" rev-parse --short HEAD)"
  log "building ${RSYNC_IMAGE} for ${platform} (first build pulls golang + ubi8-minimal, ~3–5 min)"
  podman build --platform "$platform" -t "$RSYNC_IMAGE" "$src"
fi

archive=$(mktemp -t rsync-transfer.XXXXXX).tar
podman save -o "$archive" "$RSYNC_IMAGE"
for c in "$SRC_CLUSTER" "$DST_CLUSTER"; do
  log "loading into kind cluster ${c}"
  kind load image-archive "$archive" --name "$c"
done
rm -f "$archive"

for c in "$SRC_CLUSTER" "$DST_CLUSTER"; do
  if podman exec "${c}-control-plane" crictl images 2>/dev/null | grep -q "${RSYNC_IMAGE%:*}"; then
    ok "${RSYNC_IMAGE} present on ${c}"
  else
    die "${RSYNC_IMAGE} not found on ${c} after load"
  fi
done
