#!/usr/bin/env bash
# One-screen status of both clusters and the GitOps side. --watch to loop.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl jq curl podman

report() {
  for side in src dst; do
    if [[ "$side" == src ]]; then ctx="$SRC_CTX"; port="$SRC_APP_PORT"; else ctx="$DST_CTX"; port="$DST_APP_PORT"; fi
    step "${ctx}  (shop on http://127.0.0.1:${port})"
    kubectl --context "$ctx" get deploy,pvc -o json 2>/dev/null | jq -r -f "${JQ_DIR}/workload-table.jq" | column -t || echo "   (namespace ${APP_NS} not present)"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/cache/order-1001" || true)
    printf '   order-1001 via app -> HTTP %s\n' "$code"
  done
  step "object store ${OBJ_CONTAINER} (bucket ${OBJ_BUCKET})"
  podman exec "$OBJ_CONTAINER" find "/data/${OBJ_BUCKET}" -type f 2>/dev/null | sed "s|/data/||; s/^/   /" || echo "   (not running)"
  step "Argo CD on ${DST_CTX}"
  app_status | column -t
}

if [[ "${1:-}" == "--watch" ]]; then
  while true; do clear; report; sleep 5; done
else
  report
fi
