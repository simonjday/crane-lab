# kubectl get nodes -o json -> InternalIP of the first node (used by docs/ingress-nginx-direct-mode.md)
.items[0].status.addresses[] | select(.type == "InternalIP") | .address
