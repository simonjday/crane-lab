#!/usr/bin/env bash
# shellcheck disable=SC2012  # ls output is for display only
# STEP 2 — crane transform: build a Kustomize pipeline of stages.
#   10_KubernetesPlugin   built-in clean-up (+ downscale PVC workloads, strip last-applied)
#   20_DestinationTweaks  our own stage: destination-specific changes as a reviewable patch
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
need crane yq

cd "$WORK_DIR"
[[ -d export ]] || die "run demo/01-export.sh first"

# downscale-workloads: Redis (it mounts the PVC) lands on crane-dst with replicas 0 and its
# original count in the crane.konveyor.io/original-replicas annotation — data first, then scale up.
flags='{"downscale-workloads":"true","remove-annotations":"kubectl.kubernetes.io/last-applied-configuration"}'

step "crane transform 10_KubernetesPlugin 20_DestinationTweaks"
crane transform --export-dir export --transform-dir transform --overwrite \
  --optional-flags "$flags" \
  10_KubernetesPlugin 20_DestinationTweaks

stage=transform/20_DestinationTweaks
cp "${LAB_ROOT}/demo/stage-20/podinfo-destination.patch.yaml" "${stage}/patches/"
yq -i --from-file "${YQ_DIR}/add-stage-patch.yq" "${stage}/kustomization.yaml"
ok "added our patch to ${stage}"

step "stages"
ls -1 transform | sed 's/^/   /'

step "what the KubernetesPlugin decided (one patch per resource)"
for p in transform/10_KubernetesPlugin/patches/*.yaml; do
  printf '   %-62s %s ops\n' "$(basename "$p")" "$(yq 'length' "$p")"
done

redis_patch=$(ls transform/10_KubernetesPlugin/patches/*Deployment--redis*.yaml)
step "Redis: downscaled for the cutover (from $(basename "$redis_patch"))"
yq --from-file "${YQ_DIR}/downscale-ops.yq" "$redis_patch" | sed 's/^/   /'

step "whiteouts — exported but deliberately NOT migrated"
grep -h '^# - input/' transform/10_KubernetesPlugin/kustomization.yaml | sed 's|# - input/|   |' || echo "   (none)"

log "next: demo/03-render-validate.sh"
