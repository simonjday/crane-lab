#!/usr/bin/env bash
# crane-dst platform bootstrap:
#   1. vendor Contour's static Gateway render into gitops/ (Gateway API, no Ingress)
#   2. Helm: Gitea  -> create repo, push this lab
#   3. Helm: Argo CD + root app-of-apps -> Argo CD itself deploys Contour + the HTTPRoutes from Git
# The two Helm installs are the only imperative steps on crane-dst.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need helm kubectl curl git jq yq

helm repo add gitea-charts https://dl.gitea.com/charts/ >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update gitea-charts argo >/dev/null

# ---- 1. vendor Contour Gateway render ------------------------------------------
step "vendor Contour ${CONTOUR_VERSION} static Gateway render"
cdir="${LAB_ROOT}/gitops/platform/contour"
mkdir -p "${cdir}/vendor"
render="${cdir}/vendor/contour-gateway.yaml"
curl -fsSL -o "$render" \
  "https://raw.githubusercontent.com/projectcontour/contour/${CONTOUR_VERSION}/examples/render/contour-gateway.yaml"
printf '%s\n' "$CONTOUR_VERSION" > "${cdir}/vendor/VERSION"
yq --from-file "${YQ_DIR}/select-envoy-service.yq" "$render" | yq -e --from-file "${YQ_DIR}/assert-envoy-ports.yq" >/dev/null \
  || die "envoy Service in the render doesn't have ports [80, 443] — update the nodePort patch"
yq -e --from-file "${YQ_DIR}/select-gateway.yq" "$render" >/dev/null \
  || die "render has no Gateway projectcontour/contour — update the patch and HTTPRoute parentRefs"
if yq -e --from-file "${YQ_DIR}/select-gateway-crd.yq" "$render" >/dev/null 2>&1; then
  ok "Gateway API CRDs bundled in the render"
  rm -f "${cdir}/vendor/gateway-api-crds.yaml"
  yq -i --from-file "${YQ_DIR}/drop-gateway-crds.yq" "${cdir}/kustomization.yaml"
else
  log "vendoring Gateway API ${GATEWAY_API_VERSION} standard CRDs"
  curl -fsSL -o "${cdir}/vendor/gateway-api-crds.yaml" \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  yq -i --from-file "${YQ_DIR}/add-gateway-crds.yq" "${cdir}/kustomization.yaml"
fi

# ---- 2. Gitea ----------------------------------------------------------------
step "Gitea"
set_ns "$DST_CTX" gitea
args=(upgrade --install gitea gitea-charts/gitea --kube-context "$DST_CTX" --create-namespace
      -f "${LAB_ROOT}/helm/gitea-values.yaml"
      --set-string "gitea.admin.username=${GITEA_ADMIN_USER}"
      --set-string "gitea.admin.password=${GITEA_ADMIN_PASSWORD}"
      --set-string "gitea.config.server.ROOT_URL=http://gitea.${LAB_DOMAIN}:${DST_HTTP_PORT}/"
      --wait --timeout 10m)
[[ -n "$GITEA_CHART_VERSION" ]] && args+=(--version "$GITEA_CHART_VERSION")
helm "${args[@]}"

api="http://127.0.0.1:${GITEA_PORT}/api/v1"
wait_until 180 "Gitea API on 127.0.0.1:${GITEA_PORT}" curl -fsS "${api}/version"
if ! curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" "${api}/repos/${GITEA_ADMIN_USER}/${GITEA_REPO}" >/dev/null 2>&1; then
  log "creating repo ${GITEA_ADMIN_USER}/${GITEA_REPO} (public: lab only, Argo CD needs no credentials)"
  curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" -H 'Content-Type: application/json' \
    -X POST "${api}/user/repos" \
    -d "{\"name\":\"${GITEA_REPO}\",\"private\":false,\"default_branch\":\"main\"}" >/dev/null
fi

git_commit_if_changed "crane-lab: import / update lab (Contour ${CONTOUR_VERSION} vendored)"
git_push_gitea
ok "pushed lab repo to Gitea"

# ---- 3. Argo CD + root app ---------------------------------------------------
step "Argo CD"
set_ns "$DST_CTX" argocd
args=(upgrade --install argocd argo/argo-cd --kube-context "$DST_CTX" --create-namespace
      -f "${LAB_ROOT}/helm/argocd-values.yaml" --wait --timeout 10m)
[[ -n "$ARGOCD_CHART_VERSION" ]] && args+=(--version "$ARGOCD_CHART_VERSION")
helm "${args[@]}"

args=(upgrade --install root argo/argocd-apps --kube-context "$DST_CTX"
      -f "${LAB_ROOT}/helm/argocd-apps-values.yaml"
      --set-string "applications.root.source.repoURL=${GITEA_INCLUSTER_URL}" --wait)
[[ -n "$ARGOCD_APPS_CHART_VERSION" ]] && args+=(--version "$ARGOCD_APPS_CHART_VERSION")
helm "${args[@]}"

step "Argo CD deploys the Gateway and routes from Git"
set_ns "$DST_CTX" projectcontour
wait_until 300 "Gateway projectcontour/contour Programmed" \
  bash -c "kubectl --context ${DST_CTX} get gateway contour -o json | jq -e -f ${JQ_DIR}/gateway-programmed.jq"
set_ns "$DST_CTX" argocd
wait_until 300 "Argo CD UI via Gateway API" curl -fsS -o /dev/null "http://argocd.${LAB_DOMAIN}:${DST_HTTP_PORT}/"
pw=$(kdst get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || true)
set_ns "$DST_CTX" "$APP_NS"
app_status | column -t

log "Argo CD: http://argocd.${LAB_DOMAIN}:${DST_HTTP_PORT}   admin / ${pw:-<see argocd-initial-admin-secret>}"
log "Gitea:   http://gitea.${LAB_DOMAIN}:${DST_HTTP_PORT}/${GITEA_ADMIN_USER}/${GITEA_REPO}   ${GITEA_ADMIN_USER} / (GITEA_ADMIN_PASSWORD)"
