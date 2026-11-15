# kubectl get applications.argoproj.io -o json -> APP SYNC HEALTH REVISION
(["APP", "SYNC", "HEALTH", "REVISION"] | @tsv),
(.items[] | [.metadata.name, (.status.sync.status // "-"), (.status.health.status // "-"),
             ((.status.sync.revision // "-") | .[0:7])] | @tsv)
