# gitops/apps/dst

Watched by the root Application on crane-dst (`*.yaml` only).

- `00-contour-gateway.yaml`: Contour with a static Gateway (Gateway API)
- `01-platform-routes.yaml`: HTTPRoutes for the Argo CD and Gitea UIs
- `shop.yaml`: added by `demo/04-publish.sh`. That's the moment the migrated app is onboarded to GitOps.
