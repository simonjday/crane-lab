#!/usr/bin/env bash
# Shared helpers. Source, don't execute.
# shellcheck disable=SC2034

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JQ_DIR="${LAB_ROOT}/jq"
YQ_DIR="${LAB_ROOT}/yq"
# shellcheck source=../config.env
source "${LAB_ROOT}/config.env"
WORK_DIR="${WORK_DIR:-${LAB_ROOT}/migration}"
[[ "$WORK_DIR" == /* ]] || WORK_DIR="${LAB_ROOT}/${WORK_DIR#./}"
SECRETS_DIR="${SECRETS_DIR:-${LAB_ROOT}/.secrets}"
[[ "$SECRETS_DIR" == /* ]] || SECRETS_DIR="${LAB_ROOT}/${SECRETS_DIR#./}"

export KIND_EXPERIMENTAL_PROVIDER=podman
export PATH="${HOME}/.local/bin:${PATH}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;35m### %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '   \033[1;31m✗\033[0m %s\n' "$*"; }

need() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing dependency: $c (run scripts/00-prereqs.sh)"; done
}

# Namespaces live on the kube contexts, never passed as flags.
set_ns() { kubectl config set-context "$1" --namespace="$2" >/dev/null; }
ksrc()   { kubectl --context "$SRC_CTX" "$@"; }
kdst()   { kubectl --context "$DST_CTX" "$@"; }

# wait_until <timeout-seconds> <description> <command...>
wait_until() {
  local timeout="$1" desc="$2"; shift 2
  local start; start=$(date +%s)
  printf '    waiting for %s ' "$desc"
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - start > timeout )); then echo; die "timed out after ${timeout}s waiting for ${desc}"; fi
    printf '.'; sleep 5
  done
  echo ' ok'
}

# IP of the object store container on the shared kind network
objstore_ip() {
  podman inspect "$OBJ_CONTAINER" 2>/dev/null | jq -r --arg net "$KIND_NETWORK" -f "${JQ_DIR}/container-ip.jq"
}

# The lab's Gitea-facing repo lives in .lab-git/, NOT .git/, so a GitHub clone of this lab keeps its
# own history untouched: two independent repos over the same working tree.
LAB_GIT_DIR="${LAB_ROOT}/.lab-git"
git_lab() { git --git-dir="$LAB_GIT_DIR" --work-tree="$LAB_ROOT" "$@"; }

# Keep LAB_ROOT attached to the Gitea repo. Gitea is the source of truth for gitops/ (Argo CD
# deploys from it); scripts and docs come from whatever copy of the lab you're running.
# Handles: no .lab-git (fresh clone/unzip), and a local history unrelated to / behind Gitea.
ensure_repo() {
  # ensure_repo            — call BEFORE changing gitops/: adopts Gitea's history and gitops/ content.
  # ensure_repo keep-tree  — used at commit time: adopts Gitea's history but keeps the working tree,
  #                          so the caller's pending gitops/ edits become the next commit.
  local mode="${1:-sync}"
  local remote="http://127.0.0.1:${GITEA_PORT}/${GITEA_ADMIN_USER}/${GITEA_REPO}.git"
  if [[ ! -d "$LAB_GIT_DIR" ]]; then
    git init -q -b main --bare "$LAB_GIT_DIR"
    git_lab config core.bare false
  fi
  git_lab remote get-url gitea >/dev/null 2>&1 || git_lab remote add gitea "$remote"
  git_lab fetch -q gitea main 2>/dev/null || return 0          # empty Gitea repo: first push
  if ! git_lab rev-parse -q --verify HEAD >/dev/null \
     || ! git_lab merge-base --is-ancestor gitea/main HEAD 2>/dev/null; then
    warn "local history doesn't contain Gitea's main — re-basing this folder onto gitea/main"
    git_lab reset -q gitea/main                                  # adopt Gitea history, keep local files
    [[ "$mode" == keep-tree ]] || git_lab checkout -q gitea/main -- gitops   # gitops/ = what Argo CD sees
  fi
}

git_commit_if_changed() {
  ensure_repo keep-tree
  git_lab add -A
  # Generated GitOps content is .gitignored for GitHub clones but must reach Gitea: force-add it.
  git_lab add -A -f -- gitops ':(exclude,glob)**/.DS_Store'
  if ! git_lab diff --cached --quiet; then
    git_lab commit -q -m "$1"
    log "committed: $1"
  fi
}

git_push_gitea() {
  local auth
  auth=$(printf '%s:%s' "$GITEA_ADMIN_USER" "$GITEA_ADMIN_PASSWORD" | base64)
  git_lab -c "http.extraHeader=Authorization: Basic ${auth}" push -q gitea main
}

# argocd app status line via the dst cluster API (no argocd CLI / token needed)
app_status() {
  set_ns "$DST_CTX" argocd
  kdst get applications.argoproj.io -o json | jq -r -f "${JQ_DIR}/app-status.jq"
  set_ns "$DST_CTX" "$APP_NS"
}

# deploy_scaled_ready <ctx> <deployment> — scaled above 0 with all replicas ready
deploy_scaled_ready() {
  kubectl --context "$1" get deploy "$2" -o json 2>/dev/null | jq -e -f "${JQ_DIR}/deploy-scaled-ready.jq" >/dev/null
}

# ensure_rclone_conf — (re)write .secrets/rclone.conf from the running object store.
# Everything in it is derived (config.env + container IP), so it is safe to regenerate; this keeps
# the demo working if the lab folder is replaced (e.g. Finder "Replace" on re-extracting the zip).
ensure_rclone_conf() {
  local conf="${SECRETS_DIR}/rclone.conf" ip
  podman container exists "$OBJ_CONTAINER" || die "object store '${OBJ_CONTAINER}' missing — run scripts/15-object-store.sh"
  ip=$(objstore_ip)
  [[ -n "$ip" && "$ip" != "null" ]] || die "could not determine ${OBJ_CONTAINER} IP on network ${KIND_NETWORK}"
  if [[ -s "$conf" ]] && grep -q "endpoint = http://${ip}:9000" "$conf"; then return 0; fi
  if [[ -z "${RCLONE_CONF_QUIET:-}" ]]; then
    if [[ -s "$conf" ]]; then warn "rclone.conf endpoint stale — rewriting"
    else warn "no ${conf} — regenerating from ${OBJ_CONTAINER}"; fi
  fi
  mkdir -p "$SECRETS_DIR"
  (umask 077; cat > "$conf") <<CONF
[${OBJ_REMOTE}]
type = s3
provider = Other
access_key_id = ${OBJ_ACCESS_KEY}
secret_access_key = ${OBJ_SECRET_KEY}
endpoint = http://${ip}:9000
force_path_style = true
CONF
  chmod 600 "$conf"
}
