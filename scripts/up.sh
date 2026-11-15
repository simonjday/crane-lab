#!/usr/bin/env bash
# Build everything from scratch: tools -> two clusters -> object store -> crane-dst platform
# (Argo CD, Gitea, Gateway API) -> legacy app -> arm64 transfer image -> preflight.
set -euo pipefail
dir="$(dirname "$0")"
"${dir}/00-prereqs.sh"
"${dir}/10-clusters.sh"
"${dir}/15-object-store.sh"
"${dir}/20-dst-platform.sh"
"${dir}/30-src-legacy-app.sh"
"${dir}/35-rsync-image.sh"
"${dir}/40-preflight.sh"
echo
echo "Ready. Run the demo from the repo root:  demo/01-export.sh … demo/06-verify.sh  (see DEMO.md)"
