#!/usr/bin/env bash
# Substitute variables from config/deployment-vars.env into YAML (envsubst).
# Only the variables listed in SUBST are expanded so Argo CD Helm ref $values/..., ${tag},
# and ${ELASTIC_PASSWORD} in values stay intact (GNU gettext envsubst).
# Run from anywhere: ./render-deployment-vars.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ENV_FILE="${ROOT}/config/deployment-vars.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

[[ -z "${GIT_REPO_URL:-}" ]] && { echo "GIT_REPO_URL is not set in ${ENV_FILE}" >&2; exit 1; }
[[ -z "${IDSP_PUBLIC_DOMAIN:-}" ]] && { echo "IDSP_PUBLIC_DOMAIN is not set in ${ENV_FILE}" >&2; exit 1; }
[[ -z "${SSP_HELM_REPO_URL:-}" ]] && { echo "SSP_HELM_REPO_URL is not set in ${ENV_FILE}" >&2; exit 1; }
[[ -z "${CHART_VERSION:-}" ]] && { echo "CHART_VERSION is not set in ${ENV_FILE}" >&2; exit 1; }
[[ -z "${INGRESS_LOAD_BALANCER_IP:-}" ]] && { echo "INGRESS_LOAD_BALANCER_IP is not set in ${ENV_FILE}" >&2; exit 1; }
[[ -z "${SSP_REGISTRY_PULL_SECRET_NAME:-}" ]] && { echo "SSP_REGISTRY_PULL_SECRET_NAME is not set in ${ENV_FILE}" >&2; exit 1; }
[[ -z "${SSP_GENERAL_TLS_SECRET_NAME:-}" ]] && { echo "SSP_GENERAL_TLS_SECRET_NAME is not set in ${ENV_FILE}" >&2; exit 1; }

SUBST='${GIT_REPO_URL}${IDSP_PUBLIC_DOMAIN}${SSP_HELM_REPO_URL}${CHART_VERSION}${INGRESS_LOAD_BALANCER_IP}${SSP_REGISTRY_PULL_SECRET_NAME}${SSP_GENERAL_TLS_SECRET_NAME}'

shopt -s nullglob
FILES=(
  idsp-parent-app.yaml
  apps/*.yaml
  values/*.yaml
  manifests/logging/kibana.yaml
  manifests/logging/kibana-ingress.yaml
)
shopt -u nullglob

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { echo "Skip missing: $f" >&2; continue; }
  envsubst "$SUBST" < "$f" > "${f}.tmp"
  mv "${f}.tmp" "$f"
done

echo "Rendered deployment variables into Application manifests, values/*.yaml, and Kibana logging manifests."
