#!/usr/bin/env bash
# Turn a (fresh or existing) k3s node into a running url-shortener.
# Idempotent: safe to re-run at any time.
#
# Steps: k3s (+ bundled Traefik) ready -> ArgoCD -> prod database -> per-env
# namespaces and Secrets from terraform output -> root ArgoCD Application
# (argocd/root.yaml), which deploys everything else from url-shortener-gitops
# -> smoke test of both environments.
#
# Needs: aws CLI (`aws sso login`, see docs/aws-access.md) + session-manager-plugin,
# terraform, kubectl, helm.
# Leaves an SSM tunnel to the Kubernetes API on localhost:6443 running in the
# background; use it with: export KUBECONFIG=~/.kube/url-shortener-dev.yaml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/envs/dev"
export AWS_REGION="${AWS_REGION:-eu-central-1}"
export KUBECONFIG="$HOME/.kube/url-shortener-dev.yaml"
ARGOCD_CHART_VERSION=10.10.1 # argo-cd chart (ArgoCD v3.5.4); bump deliberately

log() { printf '\n==> %s\n' "$*"; }
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

INSTANCE_ID="$(tf_out node_instance_id)"
DOMAIN="$(tf_out domain)"

log "Waiting for $INSTANCE_ID to come online in SSM"
until [ "$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' --output text)" = "Online" ]; do
  sleep 10
done

log "Fetching kubeconfig (waits for k3s to finish installing)"
CMD_ID="$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["until [ -f /etc/rancher/k3s/k3s.yaml ]; do sleep 5; done; cat /etc/rancher/k3s/k3s.yaml"]' \
  --query Command.CommandId --output text)"
until STATUS="$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query Status --output text 2>/dev/null)" && [ "$STATUS" != "Pending" ] && [ "$STATUS" != "InProgress" ]; do
  sleep 5
done
[ "$STATUS" = "Success" ] || { echo "kubeconfig fetch failed: $STATUS" >&2; exit 1; }
mkdir -p "$(dirname "$KUBECONFIG")"
( umask 077
  aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query StandardOutputContent --output text > "$KUBECONFIG" )

log "Opening SSM tunnel to the Kubernetes API on localhost:6443"
if ! kubectl get --raw /readyz >/dev/null 2>&1; then
  # A tunnel to an old (replaced) instance would hold the port: close it.
  pkill -f "AWS-StartPortForwardingSession.*localPortNumber=6443" 2>/dev/null || true
  nohup aws ssm start-session --target "$INSTANCE_ID" \
    --document-name AWS-StartPortForwardingSession \
    --parameters 'portNumber=6443,localPortNumber=6443' \
    > "${TMPDIR:-/tmp}/url-shortener-tunnel.log" 2>&1 &
  until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
fi

log "Waiting for the node and Traefik"
kubectl wait --for=condition=Ready node --all --timeout=300s
until kubectl -n kube-system get deploy/traefik >/dev/null 2>&1; do sleep 5; done
kubectl -n kube-system rollout status deploy/traefik --timeout=300s

log "Installing ArgoCD (chart $ARGOCD_CHART_VERSION)"
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" -n argocd --create-namespace \
  -f "$ROOT/argocd/values.yaml" --wait --timeout 10m

log "Prod database and role on RDS (idempotent)"
# RDS is private, so this runs as a Job inside the cluster. The admin URL is
# dev's (the master user), minus the SQLAlchemy driver suffix psql rejects.
kubectl create namespace db-admin --dry-run=client -o yaml | kubectl apply -f -
kubectl -n db-admin create secret generic db-admin \
  --from-env-file=<(printf 'ADMIN_URL=%s\nPROD_PASSWORD=%s\n' \
    "$(tf_out database_url | sed 's/+psycopg//')" "$(tf_out db_prod_password)") \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n db-admin delete job create-prod-db --ignore-not-found
kubectl -n db-admin apply -f "$ROOT/argocd/create-prod-db-job.yaml"
kubectl -n db-admin wait job/create-prod-db --for=condition=Complete --timeout=300s
kubectl delete namespace db-admin # takes the admin credentials with it

# envFrom is read only at pod start, so a rotated password needs a restart.
RESTART=()
for ENV in dev prod; do
  NS="url-shortener-$ENV"
  if [ "$ENV" = dev ]; then DB_OUT=database_url; else DB_OUT=database_url_prod; fi
  log "Namespace $NS and its Secrets"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  # Value goes through a file descriptor, never through argv (visible in `ps`).
  RESULT="$(kubectl -n "$NS" create secret generic backend-secret \
    --from-env-file=<(printf 'DATABASE_URL=%s\n' "$(tf_out "$DB_OUT")") \
    --dry-run=client -o yaml | kubectl apply -f -)"
  echo "$RESULT"
  if [[ "$RESULT" == *configured* ]]; then RESTART+=("$NS"); fi
  # Cloudflare Origin CA cert for Traefik (Cloudflare SSL mode "Full (strict)").
  kubectl -n "$NS" create secret tls origin-tls \
    --cert=<(tf_out origin_cert_pem) --key=<(tf_out origin_key_pem) \
    --dry-run=client -o yaml | kubectl apply -f -
done

log "Namespace monitoring and its Secrets"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
# Telegram bot token for Alertmanager, from ~/.config/urlshortener.env.
: "${TELEGRAM_BOT_TOKEN:?set it in ~/.config/urlshortener.env and source that file}"
kubectl -n monitoring create secret generic alertmanager-telegram \
  --from-file=bot_token=<(printf '%s' "$TELEGRAM_BOT_TOKEN") \
  --dry-run=client -o yaml | kubectl apply -f -
# Grafana admin password: generated once, kept across re-runs.
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-env-file=<(printf 'admin-password=%s\n' "$(openssl rand -base64 24 | tr -d '/+=')")
fi

log "Root Application: ArgoCD deploys apps/ from url-shortener-gitops"
kubectl apply -f "$ROOT/argocd/root.yaml"
for APP in root url-shortener-dev url-shortener-prod monitoring loki alloy monitoring-config; do
  until kubectl -n argocd get "application/$APP" >/dev/null 2>&1; do sleep 5; done
  kubectl -n argocd wait "application/$APP" --timeout=600s \
    --for=jsonpath='{.status.sync.status}'=Synced
  kubectl -n argocd wait "application/$APP" --timeout=600s \
    --for=jsonpath='{.status.health.status}'=Healthy
done

# (the +"..." form: macOS bash 3.2 with set -u rejects an empty array)
for NS in ${RESTART[@]+"${RESTART[@]}"}; do
  log "Secret changed: restarting backend in $NS"
  kubectl -n "$NS" rollout restart deploy/backend
  kubectl -n "$NS" rollout status deploy/backend --timeout=180s
done

log "Smoke test (through Cloudflare)"
for HOST in "$DOMAIN" "dev.$DOMAIN"; do
  curl -fsS --retry 5 --retry-all-errors --retry-delay 5 "https://$HOST/healthz" && echo
done
echo "prod: https://$DOMAIN   dev: https://dev.$DOMAIN"
echo "kubectl: export KUBECONFIG=$KUBECONFIG"
echo "ArgoCD UI: kubectl -n argocd port-forward svc/argocd-server 8080:443 (see argocd/values.yaml)"
