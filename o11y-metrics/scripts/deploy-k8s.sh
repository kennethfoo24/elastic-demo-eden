#!/usr/bin/env bash
# deploy-k8s.sh — Deploy OTel Astronomy Shop to an existing EDOT-enabled GKE cluster,
# pointed at the Elastic Observability serverless project.
#
# Prerequisites:
#   - opentelemetry-kube-stack already deployed in opentelemetry-operator-system
#   - elastic-secret-otel secret contains: elastic_otlp_endpoint, elastic_api_key, elastic_endpoint
#   - helm 3 + kubectl configured for the target cluster
#
# What this script does:
#   1. Patches the elastic-secret-otel secret to expose elastic_endpoint as
#      ELASTIC_ES_ENDPOINT (required by the kube-stack gateway ES exporter)
#   2. Upgrades opentelemetry-kube-stack with the OTel-demo gateway overrides:
#        - Adds transform/sanitize_spans processor (prevents APM span cardinality explosion)
#        - Adds elasticsearch/logs_otel exporter (routes logs to logs.otel wired stream
#          instead of logs-generic.otel-default — required for Knowledge Indicators + Significant Events)
#   3. Creates the o11y-metrics namespace
#   4. Deploys the OpenTelemetry Astronomy Shop demo (opentelemetry-demo helm chart)
#      which sends OTLP to the existing daemon collector and through to the gateway
#
# The kube-stack upgrade briefly restarts gateway pods (~60s). Daemon collectors
# keep running, so the trading apps' telemetry is buffered and not lost.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

EDOT_NAMESPACE="opentelemetry-operator-system"
DEMO_NAMESPACE="o11y-metrics"
SECRET_NAME="elastic-secret-otel"

step() { echo; echo "══════════════════════════════════════════════"; echo "▶  $*"; echo "══════════════════════════════════════════════"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight"
kubectl get secret "${SECRET_NAME}" -n "${EDOT_NAMESPACE}" >/dev/null 2>&1 || {
  echo "  ERROR: Secret '${SECRET_NAME}' not found in namespace '${EDOT_NAMESPACE}'."
  echo "  The EDOT kube-stack must be pre-installed. Run step 0 manually:"
  echo "    helm upgrade --install opentelemetry-kube-stack open-telemetry/opentelemetry-kube-stack \\"
  echo "      --namespace ${EDOT_NAMESPACE} --values ${TERRAFORM_DIR}/edot-values.yaml"
  exit 1
}
echo "  EDOT kube-stack: OK"
echo "  Secret '${SECRET_NAME}': OK"

# ── Step 1: Patch secret to expose elastic_endpoint as elastic_es_endpoint ────
step "1/4  Patch secret — add elastic_es_endpoint alias"
ES_ENDPOINT=$(kubectl get secret "${SECRET_NAME}" -n "${EDOT_NAMESPACE}" \
  -o jsonpath='{.data.elastic_endpoint}' | base64 -d)
echo "  ES endpoint: ${ES_ENDPOINT}"

kubectl patch secret "${SECRET_NAME}" -n "${EDOT_NAMESPACE}" \
  --type=merge \
  -p "{\"data\":{\"elastic_es_endpoint\":\"$(echo -n "${ES_ENDPOINT}" | base64 | tr -d '\n')\"}}"
echo "  Secret patched: elastic_es_endpoint = elastic_endpoint"

# ── Step 2: Upgrade kube-stack with OTel demo gateway overrides ───────────────
step "2/4  Upgrade opentelemetry-kube-stack (adds logs.otel exporter + span sanitizer)"
echo "  This restarts gateway pods (~60s). Daemon collectors keep running."

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update open-telemetry

helm upgrade opentelemetry-kube-stack \
  open-telemetry/opentelemetry-kube-stack \
  --namespace "${EDOT_NAMESPACE}" \
  --values "${TERRAFORM_DIR}/edot-values.yaml" \
  --values "${TERRAFORM_DIR}/elastic-otel-demo-kube-stack-overrides.yaml" \
  --reuse-values=false \
  --wait --timeout 5m
echo "  opentelemetry-kube-stack upgraded."

# ── Step 3: Create o11y-metrics namespace ─────────────────────────────────────
step "3/4  Create namespace '${DEMO_NAMESPACE}'"
kubectl create namespace "${DEMO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo "  Namespace '${DEMO_NAMESPACE}': ready"

# ── Step 4: Deploy OTel Astronomy Shop ───────────────────────────────────────
step "4/4  Deploy OpenTelemetry Astronomy Shop (opentelemetry-demo)"
# The chart's default values route OTLP to the daemon collector in opentelemetry-operator-system
# (see elastic-otel-demo-values.yaml: OTEL_COLLECTOR_NAME env var).
helm upgrade --install otel-demo \
  open-telemetry/opentelemetry-demo \
  --version 0.38.6 \
  --namespace "${DEMO_NAMESPACE}" \
  --values "${TERRAFORM_DIR}/elastic-otel-demo-values.yaml" \
  --values "${TERRAFORM_DIR}/local-cluster-overrides.yaml" \
  --wait --timeout 10m
echo "  OpenTelemetry Astronomy Shop deployed."

echo
echo "✅  deploy-k8s.sh complete."
echo
echo "Data should start flowing to your Observability project within ~5 minutes."
echo
echo "Verification:"
echo "  APM services:  Kibana → Observability → APM → Services"
echo "  Logs:          Kibana → Observability → Logs → Stream (filter: stream=logs.otel)"
echo "  Metrics:       Kibana → Observability → Infrastructure → Inventory"
echo "  SLOs:          Kibana → Observability → SLOs  (will turn green as data flows)"
echo
echo "Get the frontend IP (for Significant Events test / synthetics):"
echo "  kubectl get svc -n ${DEMO_NAMESPACE} otel-demo-frontendproxy"
echo
echo "k8s connector setup (for k8s action workflows in Kibana):"
echo "  Run this to get a token:"
echo "    kubectl create serviceaccount kibana-connector -n ${DEMO_NAMESPACE}"
echo "    kubectl create clusterrolebinding kibana-connector-binding \\"
echo "      --clusterrole=view --serviceaccount=${DEMO_NAMESPACE}:kibana-connector"
echo "    kubectl create token kibana-connector -n ${DEMO_NAMESPACE} --duration=87600h"
echo "  Then: Kibana → Connectors → New Connector → Webhook → otel-demo-k8s"
echo "    URL: \$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
