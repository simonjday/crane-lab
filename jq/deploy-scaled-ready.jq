# True only when a Deployment is scaled above 0 AND all desired replicas are ready.
# (`kubectl rollout status` returns success immediately for replicas: 0, so it can't be used here.)
(.spec.replicas // 0) > 0 and (.status.readyReplicas // 0) >= .spec.replicas
