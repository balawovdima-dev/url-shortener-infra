# url-shortener chart

FastAPI backend + Next.js frontend behind the k3s-bundled Traefik Ingress. The
backend owns every path except the frontend's page (`/`) and assets (`/_next`,
`/favicon.ico`), so short links (`/<code>`) and `/api/*` both reach it.

## Deploy

The chart is deployed by ArgoCD from `main` (`argocd/url-shortener.yaml`,
auto-sync with prune and self-heal): merging to `main` is the deploy. Don't
`helm upgrade` it by hand, ArgoCD would revert it.

From an empty k3s node, after `terraform apply` run:

```sh
scripts/bootstrap-cluster.sh
```

It fetches the kubeconfig over SSM, opens a tunnel to the API on
`localhost:6443`, installs ArgoCD (pinned chart version), creates the
namespace and `backend-secret` from `terraform output database_url`, the
`origin-tls` Secret from the Cloudflare Origin CA cert, applies the
Application and waits until it is Synced and Healthy. Safe to re-run.

The domain in `argocd/url-shortener.yaml` (`publicUrl`, `ingress.host`) is a
literal and must match `terraform output domain`; the script refuses to run
otherwise.

ArgoCD UI: `kubectl -n argocd port-forward svc/argocd-server 8080:443`, user
`admin`, password in the `argocd-initial-admin-secret` Secret.

## What lives outside the chart

The namespace and the `backend-secret` (`DATABASE_URL`) and `origin-tls`
Secrets are created by the script, not the chart, so pruning or deleting the
Application never deletes credentials and the password never lands in git.

## Behaviour worth knowing

- **Migrations** run as a `pre-install`/`pre-upgrade` hook Job
  (`alembic upgrade head`) before new backend pods start. Disable with
  `backend.migrations.enabled=false`.
- Changing `backend.config` or `publicUrl` rolls the backend pods automatically
  (`checksum/config` annotation).
- `publicUrl` is required; the backend builds short links from it.
- With `ingress.tlsSecret` set, Traefik serves the routes on 443 only; plain
  HTTP to the node returns 404. That's fine behind Cloudflare, which always
  connects over HTTPS ("Full (strict)") and redirects visitors to HTTPS.
- Images are still `:latest`, so a new image is picked up only when pods
  restart. Next step: pin `backend.image.tag`/`frontend.image.tag` to a git
  SHA (from the app repo's CI, or ArgoCD Image Updater).
