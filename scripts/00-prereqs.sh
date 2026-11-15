#!/usr/bin/env bash
# CLI prerequisites, the crane binary, and a sanity check of the Podman machine.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ "$(uname -s)" == "Darwin" ]] || warn "written for macOS; continuing anyway"

log "installing CLI tools via Homebrew (idempotent)"
brew install --quiet kind kubectl helm jq yq skopeo git curl gettext

# Podman: only the CLI + a Podman machine are needed. Podman Desktop is optional (a GUI over the same
# machine). If podman is already installed (Podman Desktop / the podman.io installer put it in
# /opt/podman/bin), don't add a second, possibly different-version copy from Homebrew.
if command -v podman >/dev/null 2>&1; then
  log "podman: $(command -v podman) — $(podman --version) (existing install, not touched)"
else
  log "installing podman via Homebrew"
  brew install --quiet podman
fi

# ---- crane -------------------------------------------------------------------
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
bin_dir="${HOME}/.local/bin"; mkdir -p "$bin_dir"
want="${CRANE_VERSION#v}"
have=$("${bin_dir}/crane" version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [[ "$have" != "$want" ]]; then
  log "installing crane ${CRANE_VERSION} (darwin/${arch})"
  curl -fL --progress-bar -o "${bin_dir}/crane" \
    "https://github.com/konveyor/crane/releases/download/${CRANE_VERSION}/crane_darwin_${arch}"
  chmod +x "${bin_dir}/crane"
  xattr -d com.apple.quarantine "${bin_dir}/crane" 2>/dev/null || true
fi
log "crane: $(command -v crane) — $(crane version 2>/dev/null | head -1)"
grep -q '.local/bin' "${HOME}/.zshrc" 2>/dev/null || warn "add to ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\""

# ---- Podman machine ----------------------------------------------------------
podman machine inspect "$PODMAN_MACHINE" >/dev/null 2>&1 \
  || die "Podman machine '${PODMAN_MACHINE}' not found. Create one (or use Podman Desktop → Settings → Resources):
      podman machine init --cpus 6 --memory 12288 --disk-size 40 --rootful ${PODMAN_MACHINE}
      podman machine start ${PODMAN_MACHINE}"
info=$(podman machine inspect "$PODMAN_MACHINE")
log "Podman machine: $(jq -r -f "${JQ_DIR}/machine-summary.jq" <<<"$info")"
[[ "$(jq -r '.[0].State' <<<"$info")" == "running" ]] || die "start it: podman machine start ${PODMAN_MACHINE}"
[[ "$(jq -r '.[0].Rootful' <<<"$info")" == "true" ]] || die "kind on Podman needs a rootful machine: podman machine set --rootful ${PODMAN_MACHINE}"
(( $(jq -r '.[0].Resources.Memory' <<<"$info") >= PODMAN_MIN_MEM_MIB )) \
  || warn "machine has < ${PODMAN_MIN_MEM_MIB} MiB; two clusters + Argo CD + Gitea may be tight"

# Other kind clusters share the machine's RAM
others=$(podman ps --format '{{.Names}}' | grep -- '-control-plane$' | grep -v -e "^${SRC_CLUSTER}-" -e "^${DST_CLUSTER}-" || true)
if [[ -n "$others" ]]; then
  warn "other kind clusters are running and share the Podman machine's memory:"
  # shellcheck disable=SC2086  # one cluster name per line
  printf '      %s\n' $others >&2
  warn "consider pausing them for the demo, e.g.: podman stop konveyor-lab-control-plane  (podman start … resumes it)"
fi

# ---- Ports -------------------------------------------------------------------
for p in "$SRC_APP_PORT" "$DST_APP_PORT" "$DST_HTTP_PORT" "$GITEA_PORT"; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && ! podman ps --format '{{.Names}}' | grep -qE "^(${SRC_CLUSTER}|${DST_CLUSTER})-"; then
    die "host port ${p} is already in use — change it in config.env"
  fi
done

log "prereqs OK"
