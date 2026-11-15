# kubectl get deploy,pvc -o json -> KIND NAME STATE
(["KIND", "NAME", "STATE"] | @tsv),
(.items[]
 | if .kind == "Deployment" then
     ["deploy", .metadata.name, "\(.status.readyReplicas // 0)/\(.spec.replicas)_ready"]
   else
     ["pvc", .metadata.name, "\(.status.phase)_\(.status.capacity.storage // .spec.resources.requests.storage)_sc=\(.spec.storageClassName // "-")"]
   end
 | @tsv)
