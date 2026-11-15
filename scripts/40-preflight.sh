#!/usr/bin/env bash
# Prove what crane transfer-pvc (indirect mode) depends on BEFORE demoing: clusters, storage,
# the transfer image, the Gateway, and that pods on BOTH clusters can reach the object store.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need crane kubectl jq skopeo podman

fail=0
check() { if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fail=1; fi; }

step "tools"
desc="crane $(crane version 2>/dev/null | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; check command -v crane

step "clusters"
desc="${SRC_CTX} reachable"; check ksrc get --raw /readyz
desc="${DST_CTX} reachable"; check kdst get --raw /readyz
desc="StorageClass 'standard' on both (transfer-pvc defaults to the source class)"
check bash -c "kubectl --context ${SRC_CTX} get sc standard && kubectl --context ${DST_CTX} get sc standard"
set_ns "$DST_CTX" projectcontour
desc="Gateway projectcontour/contour Programmed on ${DST_CLUSTER}"
check bash -c "kubectl --context ${DST_CTX} get gateway contour -o json | jq -e -f ${JQ_DIR}/gateway-programmed.jq"
set_ns "$DST_CTX" "$APP_NS"

step "transfer image ${RSYNC_IMAGE}"
if [[ "$RSYNC_IMAGE" == localhost/* ]]; then
  for c in "$SRC_CLUSTER" "$DST_CLUSTER"; do
    desc="side-loaded on ${c}"
    check bash -c "podman exec ${c}-control-plane crictl images | grep -q '${RSYNC_IMAGE%:*}'"
  done
  (( fail )) && warn "run scripts/35-rsync-image.sh"
else
  platforms=$(skopeo inspect --raw "docker://${RSYNC_IMAGE}" 2>/dev/null | jq -r -f "${JQ_DIR}/platforms.jq" || echo "unreachable")
  node_arch=$(kdst get nodes -o json | jq -r -f "${JQ_DIR}/node-arch.jq")
  if [[ "$platforms" == *"linux/${node_arch}"* || ( "$platforms" == "single-arch manifest" && "$node_arch" == "amd64" ) ]]; then
    ok "${RSYNC_IMAGE} matches node arch ${node_arch} (${platforms})"
  else
    bad "${RSYNC_IMAGE} has no linux/${node_arch} build (${platforms})"; fail=1
  fi
fi

step "object store ${OBJ_CONTAINER} (the transfer path)"
desc="container running on network '${KIND_NETWORK}'"
check bash -c "podman inspect ${OBJ_CONTAINER} | jq -e -f ${JQ_DIR}/container-running.jq"
( ensure_rclone_conf ) || true   # self-heal; failures are reported by the checks below
desc="rclone config ${SECRETS_DIR}/rclone.conf"; check test -s "${SECRETS_DIR}/rclone.conf"
ip=$(objstore_ip || true)
if [[ -z "$ip" ]]; then
  bad "no IP for ${OBJ_CONTAINER} — run scripts/15-object-store.sh"; fail=1
else
  # Unauthenticated GET on an S3 endpoint returns 403 (or 200/400) — any HTTP answer proves reachability.
  trap 'set_ns "$SRC_CTX" "$APP_NS"; set_ns "$DST_CTX" "$APP_NS"' EXIT   # restore even on failure
  for side in src dst; do
    ctx="$SRC_CTX"; [[ "$side" == dst ]] && ctx="$DST_CTX"
    pod="crane-preflight-${side}-$(date +%s)"
    # Probe in 'default': 'shop' doesn't exist on crane-dst until Argo CD syncs it (demo step 04).
    set_ns "$ctx" default
    kubectl --context "$ctx" run "$pod" --restart=Never --image="$CURL_IMAGE" --command -- \
      sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${ip}:9000/ || echo 000" >/dev/null
    wait_until 120 "${side} probe pod" \
      bash -c "kubectl --context ${ctx} get pod ${pod} -o jsonpath='{.status.phase}' | grep -Eq 'Succeeded|Failed'"
    code=$(kubectl --context "$ctx" logs "$pod" 2>/dev/null | tail -1 | tr -dc '0-9')
    kubectl --context "$ctx" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
    set_ns "$ctx" "$APP_NS"
    if [[ "$code" =~ ^(200|400|403)$ ]]; then
      ok "pods on ${ctx} reach http://${ip}:9000 (HTTP ${code})"
    else
      bad "pods on ${ctx} can't reach http://${ip}:9000 (got '${code}')"; fail=1
    fi
  done
fi

echo
if (( fail )); then die "preflight failed — fix the items above before running the demo"; fi
log "preflight passed — transfer path: ${SRC_CLUSTER} → http://${ip}:9000/${OBJ_BUCKET} → ${DST_CLUSTER}"
