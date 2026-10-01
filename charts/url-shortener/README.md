# url-shortener chart

FastAPI backend + Next.js frontend behind an nginx Ingress. The backend owns every
path except the frontend's page (`/`) and assets (`/_next`, `/favicon.ico`), so
short links (`/<code>`) and `/api/*` both reach it.

## Prerequisites (not managed by the chart)

The namespace and the DB Secret live outside the release, so `helm uninstall`
never deletes credentials.

```sh
kubectl create namespace url-shortener
kubectl -n url-shortener create secret generic backend-secret \
  --from-literal=DATABASE_URL='postgresql+psycopg://shortener:<password>@<rds-endpoint>:5432/shortener'
```

Run migrations once per new database:

```sh
kubectl -n url-shortener exec deploy/backend -- alembic upgrade head
```

## Install / upgrade

```sh
helm upgrade --install url-shortener charts/url-shortener -n url-shortener \
  --set backend.image.tag=<git-sha> --set frontend.image.tag=<git-sha>
```

- Changing `backend.config` or `publicUrl` rolls the backend pods automatically
  (`checksum/config` annotation).
- `helm upgrade` without `-f`/`--set` **reuses the previous release's values**;
  pass `--reset-values` to go back to `values.yaml`.
- The release uses client-side apply (`--server-side=false`, sticky via `auto`),
  because its resources were adopted from `kubectl apply` and server-side apply
  conflicts on fields kubectl used to own.

## Local access

```sh
kubectl port-forward -n ingress-nginx service/ingress-nginx-controller 18080:80
open http://127.0.0.1:18080
```

`publicUrl` must match the origin the browser uses — the backend builds short
links from it.
