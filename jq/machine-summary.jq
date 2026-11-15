# podman machine inspect -> one-line summary
.[0] | "\(.Name) state=\(.State) cpus=\(.Resources.CPUs) memMiB=\(.Resources.Memory) rootful=\(.Rootful)"
