# url-shortener chart

FastAPI backend + Next.js frontend behind the k3s-bundled Traefik Ingress. The
backend owns every path except the frontend's page (`/`) and assets (`/_next`,
`/favicon.ico`), so short links (`/<code>`) and `/api/*` both reach it.

## Deploy

Normally you don't call Helm directly — after `terraform apply` run:

```sh
scripts/bootstrap-cluster.sh
```

It fetches the kubeconfig over SSM, opens a tunnel to the API on
`localhost:6443`, creates the namespace and `backend-secret` from
`terraform output database_url`, and installs this chart with
`publicUrl=http://<node EIP>`. Safe to re-run.

## What lives outside the chart

The namespace and the `backend-secret` Secret (`DATABASE_URL`) are created by the
script, not the release, so `helm uninstall` never deletes credentials and the
password never lands in Helm release history.

## Behaviour worth knowing

- **Migrations** run as a `pre-install`/`pre-upgrade` hook Job
  (`alembic upgrade head`) before new backend pods start. Disable with
  `backend.migrations.enabled=false`.
- Changing `backend.config` or `publicUrl` rolls the backend pods automatically
  (`checksum/config` annotation).
- `publicUrl` is required; the backend builds short links from it.
- `helm upgrade` without `-f`/`--set` **reuses the previous release's values**;
  pass `--reset-values` to go back to `values.yaml`.
- Pin images per deploy: `--set backend.image.tag=<git-sha> --set frontend.image.tag=<git-sha>`.
