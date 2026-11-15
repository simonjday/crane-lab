# skopeo inspect --raw -> "linux/amd64, linux/arm64" (single-arch manifests report "single-arch")
if .manifests then
  [.manifests[]?.platform | select(. != null) | "\(.os)/\(.architecture)"] | unique | join(", ")
else
  "single-arch manifest"
end
