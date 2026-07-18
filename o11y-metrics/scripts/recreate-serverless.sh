#!/usr/bin/env bash
# recreate-serverless.sh — Import all o11y-metrics config into an Elastic Observability serverless project.
#
# Uses ecat (the EDEN content-importer framework) directly — no Docker build required.
# Python 3.10+ and pip packages (requests, elasticsearch, pyyaml) must be installed.
#
# Usage:
#   export OBSERVABILITY_KIBANA_URL=https://my-project.kb.us-east-1.aws.elastic.cloud
#   export OBSERVABILITY_ES_URL=https://my-project.es.us-east-1.aws.elastic.cloud
#   export OBSERVABILITY_API_KEY=<base64-encoded-api-key>
#   ./recreate-serverless.sh
#
# Skipped types (require running k8s/GKE infrastructure):
#   - connectors  (otel-demo-k8s + snowem require k8s SA token and service IPs)
#   - synthetics  (synthetic monitors have hardcoded OTel demo frontend IPs)
#   - wiki        (requires in-cluster wiki.js + postgres sidecar)
#   - servicenow  (requires snowem sidecar)
#
# NOTE: SLOs, alerts, and workflows reference connectors that won't exist.
# They will import successfully but fail at runtime until connectors are configured.
# For a live-data demo, wire up:
#   - An HTTP connector for the OTel demo k8s API (or skip k8s-action workflows)
#   - An OTLP source (EDOT or live app) pointing at your project's ingest endpoint

set -euo pipefail

: "${OBSERVABILITY_KIBANA_URL:?Set OBSERVABILITY_KIBANA_URL}"
: "${OBSERVABILITY_ES_URL:?Set OBSERVABILITY_ES_URL}"
: "${OBSERVABILITY_API_KEY:?Set OBSERVABILITY_API_KEY}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ECAT_DIR="${SCRIPT_DIR}/../docker/content-importer/ecat"
CONTENT_DIR="${SCRIPT_DIR}/../docker/content-importer/content"

step() { echo; echo "══════════════════════════════════════════════"; echo "▶  $*"; echo "══════════════════════════════════════════════"; }

step "Preflight checks"
python3 -c "import requests, elasticsearch, yaml" 2>/dev/null || {
  echo "  Installing required Python packages..."
  pip3 install -q requests elasticsearch pyyaml
}
echo "  Python packages: OK"
echo "  ecat: ${ECAT_DIR}/ecat.py"
echo "  content: ${CONTENT_DIR}"

# Types to import (skip: connectors, synthetics, wiki, servicenow)
IMPORT_TYPES=(
  ingest_pipelines
  ml_integrations
  slos
  dashboards
  data_views
  alerts
  knowledge_indicators
  significant_events
  workflows
  agentbuilder_tools
  agentbuilder_skills
  agentbuilder_agents
)

step "Running ecat import (types: ${IMPORT_TYPES[*]})"
echo "  Target Kibana: ${OBSERVABILITY_KIBANA_URL}"
echo "  Target ES:     ${OBSERVABILITY_ES_URL}"
echo

KIBANA_URL="${OBSERVABILITY_KIBANA_URL}" \
ELASTICSEARCH_URL="${OBSERVABILITY_ES_URL}" \
ELASTIC_API_KEY="${OBSERVABILITY_API_KEY}" \
KNOWLEDGE_INDICATORS_STREAM="logs.otel" \
SIGNIFICANT_EVENTS_STREAM="logs.otel" \
python3 "${ECAT_DIR}/ecat.py" \
  --action import \
  --folder "${CONTENT_DIR}" \
  --types "${IMPORT_TYPES[@]}"

echo
echo "✅  recreate-serverless.sh complete."
echo
echo "Verification checklist:"
echo "  □  SLOs visible under Observability → SLOs"
echo "  □  Alert rules visible under Observability → Alerts → Rules"
echo "  □  Dashboards visible (Chatbot RAG LLM Observability)"
echo "  □  Data views: logs*, synthetics-*, ragas-eval-scores"
echo "  □  Workflows listed in Kibana Workflows UI"
echo "  □  Agent Builder shows 'Elastic Agent' with tools"
echo "  □  Significant Events visible under Streams → Significant Events (once logs.otel has data)"
echo "  □  Knowledge Indicators visible in Streams (once logs.otel has data)"
echo
echo "Next steps for live data:"
echo "  □  Point an EDOT collector at: ${OBSERVABILITY_ES_URL%%.es.*}.ingest.${OBSERVABILITY_ES_URL#*.}"
echo "  □  Or send OTLP traces/metrics/logs to the APM endpoint"
echo "  □  Create an HTTP connector for OTel demo k8s API (for k8s action workflows)"
