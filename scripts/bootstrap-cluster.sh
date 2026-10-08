#!/usr/bin/env bash
# Turn a (fresh or existing) k3s node into a running url-shortener.
# Idempotent: safe to re-run at any time.
#
# Steps: k3s (+ bundled Traefik) ready -> ArgoCD -> Secrets from terraform
# output -> ArgoCD Application for charts/url-shortener -> smoke test.
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
NS=url-shortener
ARGOCD_CHART_VERSION=10.10.1 # argo-cd chart (ArgoCD v3.5.4); bump deliberately
APP_MANIFEST="$ROOT/argocd/url-shortener.yaml"

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

log "Namespace, DB and TLS Secrets"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# Value goes through a file descriptor, never through argv (visible in `ps`).
SECRET_RESULT="$(kubectl -n "$NS" create secret generic backend-secret \
  --from-env-file=<(printf 'DATABASE_URL=%s\n' "$(tf_out database_url)") \
  --dry-run=client -o yaml | kubectl apply -f -)"
echo "$SECRET_RESULT"
# Cloudflare Origin CA cert for Traefik (Cloudflare SSL mode "Full (strict)").
kubectl -n "$NS" create secret tls origin-tls \
  --cert=<(tf_out origin_cert_pem) --key=<(tf_out origin_key_pem) \
  --dry-run=client -o yaml | kubectl apply -f -

log "Deploying the chart via ArgoCD (migrations run as a PreSync hook)"
# The Application lives in git, so its domain is a literal: keep it in sync.
grep -q "host: $DOMAIN\$" "$APP_MANIFEST" || {
  echo "$APP_MANIFEST does not use domain $DOMAIN (terraform output domain)" >&2
  exit 1
}
# One-time hand-over from a plain Helm release: drop only Helm's release
# records (never `helm uninstall`, which deletes the app); ArgoCD adopts the
# resources, which keep their names and selectors.
kubectl -n "$NS" delete secret -l owner=helm,name=url-shortener --ignore-not-found
kubectl apply -f "$APP_MANIFEST"
kubectl -n argocd wait application/url-shortener --timeout=600s \
  --for=jsonpath='{.status.sync.status}'=Synced
kubectl -n argocd wait application/url-shortener --timeout=600s \
  --for=jsonpath='{.status.health.status}'=Healthy

# envFrom is read only at pod start, so a rotated password needs a restart.
if [[ "$SECRET_RESULT" == *configured* ]]; then
  log "Secret changed: restarting backend"
  kubectl -n "$NS" rollout restart deploy/backend
  kubectl -n "$NS" rollout status deploy/backend --timeout=180s
fi

log "Smoke test (through Cloudflare)"
curl -fsS --retry 5 --retry-all-errors --retry-delay 5 "https://$DOMAIN/healthz" && echo
echo "App: https://$DOMAIN"
echo "kubectl: export KUBECONFIG=$KUBECONFIG"
echo "ArgoCD UI: kubectl -n argocd port-forward svc/argocd-server 8080:443 (see argocd/values.yaml)"
