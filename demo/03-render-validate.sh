#!/usr/bin/env bash
# shellcheck disable=SC2012  # ls output is for display only
# STEP 3 — crane apply (render, local only) + crane validate (GVK check against crane-dst).
# Nothing touches either cluster here except a read-only API discovery on crane-dst.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
need crane yq

cd "$WORK_DIR"
[[ -d transform ]] || die "run demo/02-transform.sh first"

step "crane apply — render all stages to clean manifests (writes files, not to a cluster)"
crane apply --transform-dir transform --output-dir output --overwrite

step "rendered resources (output/resources/${APP_NS}/)"
ls -1 output/resources/"$APP_NS" | sed 's/^/   /'

dep="output/resources/${APP_NS}/Deployment_apps_v1_${APP_NS}_podinfo.yaml"
step "podinfo after both stages: drift kept, runtime noise gone, destination message applied"
yq --from-file "${YQ_DIR}/rendered-podinfo.yq" "$dep" | sed 's/^/   /'

step "crane validate --context ${DST_CTX}"
crane validate --context "$DST_CTX" --input-dir output --validate-dir validate --overwrite

log "next: demo/04-publish.sh"
