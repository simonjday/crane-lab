# kubectl get gateway -o json -> true if the Gateway reports Programmed=True
[.status.conditions[]? | select(.type == "Programmed" and .status == "True")] | length > 0
