#!/usr/bin/env bash
# Stand up the "legacy" shop on crane-src the way it was really done: kubectl apply,
# then live hot-fixes nobody wrote back to Git. Then seed it with order data in Redis.
#
# kubectl apply here is deliberate — it IS the anti-pattern the demo migrates away from.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl envsubst curl

export REDIS_TAG PODINFO_TAG

step "deploy legacy shop on ${SRC_CLUSTER} (imperative, on purpose)"
# shellcheck disable=SC2016  # envsubst takes the literal variable list
envsubst '${REDIS_TAG} ${PODINFO_TAG}' < "${LAB_ROOT}/legacy-app/shop.yaml" | ksrc apply -f -
set_ns "$SRC_CTX" "$APP_NS"
ksrc rollout status deploy/redis --timeout=180s
ksrc rollout status deploy/podinfo --timeout=180s

step "simulate configuration drift (prod hot-fixes, never committed anywhere)"
ksrc set env deploy/podinfo PODINFO_UI_MESSAGE="Shop v1.0.3 — hot-fixed in prod, running on crane-src" >/dev/null
ksrc scale deploy/podinfo --replicas=2 >/dev/null
ksrc annotate deploy/podinfo ops.example.com/last-change="emergency fix INC-4711, no PR" --overwrite >/dev/null
ksrc rollout status deploy/podinfo --timeout=180s
ok "podinfo: 2 replicas, new UI message, ops annotation — none of it in any manifest"

step "seed order data into Redis via the app"
url="http://127.0.0.1:${SRC_APP_PORT}"
wait_until 120 "shop on ${url}" curl -fsS "${url}/readyz"
while IFS=$'\t' read -r key value; do
  [[ -z "$key" ]] && continue
  curl -fsS -X POST --data "$value" "${url}/cache/${key}" >/dev/null
  printf '   %-12s %s\n' "$key" "$(curl -fsS "${url}/cache/${key}")"
done < "${LAB_ROOT}/demo/seed-data.tsv"
ksrc exec deploy/redis -- redis-cli BGSAVE >/dev/null 2>&1 || true

log "shop UI on crane-src: ${url}   (orders: ${url}/cache/order-1001)"
