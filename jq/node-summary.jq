# kubectl get nodes -o json -> "name ip k8s-version arch"
.items[0] | "\(.metadata.name)  \(.status.addresses[] | select(.type == "InternalIP") | .address)  \(.status.nodeInfo.kubeletVersion)  \(.status.nodeInfo.architecture)"
