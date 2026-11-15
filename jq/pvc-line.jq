# kubectl get pvc <name> -o json -> one line
"\(.metadata.namespace)/\(.metadata.name)  \(.status.phase)  \(.status.capacity.storage // "-")  sc=\(.spec.storageClassName // "-")  pv=\(.spec.volumeName // "-")"
