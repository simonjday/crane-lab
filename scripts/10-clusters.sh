#!/usr/bin/env bash
# Create crane-src and crane-dst on the shared Podman 'kind' network (the object store joins it next).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kind kubectl envsubst jq podman

export SRC_CLUSTER DST_CLUSTER LISTEN_ADDRESS SRC_APP_PORT DST_APP_PORT DST_HTTP_PORT GITEA_PORT

create() {
  local name="$1" tmpl="$2" rendered
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    log "kind cluster '${name}' already exists"; return
  fi
  rendered=$(mktemp -t "kind-${name}.XXXXXX")
  envsubst < "$tmpl" > "$rendered"
  log "creating kind cluster '${name}'"
  local args=(create cluster --name "$name" --config "$rendered" --wait 5m)
  [[ -n "$KIND_NODE_IMAGE" ]] && args+=(--image "$KIND_NODE_IMAGE")
  kind "${args[@]}"
  rm -f "$rendered"
}

create "$SRC_CLUSTER" "${LAB_ROOT}/kind/src.yaml"
create "$DST_CLUSTER" "${LAB_ROOT}/kind/dst.yaml"

# Podman applies a default pids limit (2048) to every container, including kind nodes.
# Argo CD, Gitea, Envoy and the transfer pods together can exhaust it
# (symptom: "pthread_create() failed (11: Resource temporarily unavailable)"). Lift it.
for name in "$SRC_CLUSTER" "$DST_CLUSTER"; do
  if podman update --pids-limit=-1 "${name}-control-plane" >/dev/null 2>&1; then
    ok "${name}: pids limit lifted"
  else
    warn "${name}: could not lift the pids limit (podman update --pids-limit=-1 ${name}-control-plane)"
  fi
done

set_ns "$SRC_CTX" "$APP_NS"
set_ns "$DST_CTX" "$APP_NS"

log "nodes"
for c in "$SRC_CTX" "$DST_CTX"; do
  printf '    %-16s %s\n' "$c" "$(kubectl --context "$c" get nodes -o json | jq -r -f "${JQ_DIR}/node-summary.jq")"
done
log "both contexts default to namespace '${APP_NS}'; both nodes are on Podman network '${KIND_NETWORK}'"
