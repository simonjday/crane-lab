#!/usr/bin/env bash
# shellcheck disable=SC2012  # ls output is for display only
# STEP 1 — crane export: read-only discovery of everything in the shop namespace on crane-src.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
need crane kubectl jq yq

mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
set_ns "$SRC_CTX" "$APP_NS"

step "crane export --context ${SRC_CTX}   (namespace '${APP_NS}' from the context)"
crane export --context "$SRC_CTX" --export-dir export --overwrite

step "what came back (export/resources/${APP_NS}/)"
ls export/resources/"$APP_NS" | sed 's/_.*//' | sort | uniq -c | sed 's/^/   /'
[[ -d export/failures/$APP_NS ]] && [[ -n "$(ls -A "export/failures/${APP_NS}" 2>/dev/null)" ]] && warn "some resources failed to export: export/failures/${APP_NS}"

dep=$(ls export/resources/"$APP_NS"/Deployment_apps_v1_"$APP_NS"_podinfo.yaml)
step "the drift is captured — live podinfo Deployment, not the original manifest"
yq --from-file "${YQ_DIR}/drift.yq" "$dep" | sed 's/^/   /'

step "…along with runtime noise that must not go to another cluster"
yq --from-file "${YQ_DIR}/runtime-noise.yq" "$dep" | sed 's/^/   /'

log "next: demo/02-transform.sh"
