#!/usr/bin/env bash
# STEP 6 — prove it: every order seeded on crane-src is served by the shop on crane-dst.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
need curl kubectl jq

set_ns "$DST_CTX" "$APP_NS"
ready=$(kdst get deploy redis -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
if [[ "${ready:-0}" -lt 1 ]]; then
  die "Redis on ${DST_CLUSTER} isn't running (0 ready) — the cutover scale-up commit hasn't landed. Finish demo/05-cutover.sh first."
fi

url="http://127.0.0.1:${DST_APP_PORT}"
wait_until 120 "shop on ${url}" curl -fsS "${url}/readyz"

step "orders read through the app on ${DST_CLUSTER}"
pass=0; total=0
while IFS=$'\t' read -r key want; do
  [[ -z "$key" ]] && continue
  total=$((total + 1))
  got=$(curl -fsS "${url}/cache/${key}" 2>/dev/null || true)
  if [[ "$got" == "$want" ]]; then ok "${key}  ${got}"; pass=$((pass + 1)); else bad "${key}  expected '${want}', got '${got}'"; fi
done < "${LAB_ROOT}/demo/seed-data.tsv"

step "UI message on ${DST_CLUSTER}"
curl -fsS "${url}/" -H 'Accept: application/json' | jq -r -f "${JQ_DIR}/podinfo-message.jq" | sed 's/^/   /'

echo
if (( pass == total )); then
  log "${pass}/${total} orders migrated intact. Open ${url} and compare with http://127.0.0.1:${SRC_APP_PORT}"
else
  die "${pass}/${total} orders matched"
fi
