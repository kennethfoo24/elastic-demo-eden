#!/usr/bin/env bash
# recreate-serverless.sh — Deploy an o11y-launch-demo scenario to the
# Elastic Observability serverless project using the Python deployer directly.
#
# Runs the ScenarioDeployer from docker/elastic-launch-demo/elastic_config/
# against the serverless project — no Docker required.
#
# Usage:
#   export OBSERVABILITY_KIBANA_URL=https://...
#   export OBSERVABILITY_ES_URL=https://...
#   export OBSERVABILITY_API_KEY=<apikey>
#   ./scripts/recreate-serverless.sh [scenario_id]
#
# Scenario IDs: space (default), banking, ecommerce, financial, gaming,
#               gcp, healthcare, manufacturing, telecom, fanatics
#
# The deployer creates (for the chosen scenario):
#   - Wired-stream forks: logs.otel.<ns> and logs.ecs.<ns>
#   - Kibana Workflows (7 templated workflows)
#   - Elasticsearch knowledge-base index with ~20 docs
#   - Agent Builder tools + the AI analyst agent
#   - Knowledge Indicators + Significant Events (bound to logs.otel.<ns>)
#   - Data views (6 per scenario)
#   - Kibana dashboards (exec + business-exec)
#   - Alert rules (~20)
#   - 12h synthetic APM rollup data (transactions, service map, ML training)
#   - 12h synthetic ECS access-log backfill
#   - ML anomaly detection jobs (log rate + categorization)
#   - SLOs (availability, latency, error rate)
#   - OTel integrations (kubernetes_otel, nginx_otel, mysql_otel, vpc flow x2)
#
# The live telemetry generators (OTLP chaos faults, KPI metrics, log streams)
# are NOT started by this script — those need the Docker app or a k8s deployment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="${SCRIPT_DIR}/.."
APP_DIR="${DEMO_DIR}/docker/elastic-launch-demo"
VENV_DIR="${SCRIPT_DIR}/.venv-serverless"

SCENARIO_ID="${1:-space}"

# ── Credentials from environment (required) ───────────────────────────────
KIBANA_URL="${OBSERVABILITY_KIBANA_URL:-}"
ES_URL="${OBSERVABILITY_ES_URL:-}"
API_KEY="${OBSERVABILITY_API_KEY:-}"

if [[ -z "${KIBANA_URL}" || -z "${API_KEY}" ]]; then
  echo "ERROR: Set OBSERVABILITY_KIBANA_URL and OBSERVABILITY_API_KEY"
  echo "  export OBSERVABILITY_KIBANA_URL=https://kenneth-sandbox-d54ee0.kb.asia-southeast1.gcp.elastic.cloud"
  echo "  export OBSERVABILITY_ES_URL=https://kenneth-sandbox-d54ee0.es.asia-southeast1.gcp.elastic.cloud"
  echo "  export OBSERVABILITY_API_KEY=<key>"
  exit 1
fi

# The deployer can derive ES URL from Kibana URL, but explicit is safer.
ES_URL="${ES_URL:-}"

step() { echo; echo "══════════════════════════════════════════════"; echo "▶  $*"; echo "══════════════════════════════════════════════"; }

# ── Step 1: Python venv ───────────────────────────────────────────────────
step "1/3  Set up Python venv"
if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
  python3 -m venv "${VENV_DIR}"
  echo "  Created venv at ${VENV_DIR}"
fi
source "${VENV_DIR}/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet httpx[http2] pyyaml python-dotenv h2
echo "  Python deps installed (httpx, pyyaml, python-dotenv)"

# ── Step 2: Validate scenario ─────────────────────────────────────────────
step "2/3  Validate scenario '${SCENARIO_ID}'"
VALID_SCENARIOS="space banking ecommerce financial gaming gcp healthcare manufacturing telecom fanatics"
if ! echo "${VALID_SCENARIOS}" | grep -qw "${SCENARIO_ID}"; then
  echo "  ERROR: Unknown scenario '${SCENARIO_ID}'"
  echo "  Valid scenarios: ${VALID_SCENARIOS}"
  exit 1
fi
echo "  Scenario: ${SCENARIO_ID}"
echo "  Kibana:   ${KIBANA_URL}"
echo "  ES URL:   ${ES_URL:-<will be derived from Kibana URL>}"

# ── Step 3: Run deployer ──────────────────────────────────────────────────
step "3/3  Run deployer for '${SCENARIO_ID}'"
echo "  This takes 5-10 minutes (ML job setup, integrations warm-up)."
echo

cd "${APP_DIR}"

# Export env vars for app.config so its module-level imports succeed
# (app.telemetry imports app.config at import time).
export ACTIVE_SCENARIO="${SCENARIO_ID}"
export KIBANA_URL="${KIBANA_URL}"
export ELASTIC_URL="${ES_URL}"
export ELASTIC_API_KEY="${API_KEY}"
# OTLP vars are needed for app.telemetry to import without error.
# Set them to the serverless OTLP ingest endpoint so backfill generators
# can emit live docs if needed (the deployer only backfills, doesn't run live).
OTLP_URL="${KIBANA_URL/\.kb\./.ingest.}"
export OTLP_ENDPOINT="${OTLP_URL}:443"
export OTLP_API_KEY="${API_KEY}"

PYTHONPATH="${APP_DIR}" python3 - <<'PYEOF'
import sys
import logging
import os

# Wire up logging so deployer step output is visible
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stdout,
)
# Keep httpx quiet
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

scenario_id = os.environ["ACTIVE_SCENARIO"]
kibana_url  = os.environ["KIBANA_URL"].rstrip("/")
api_key     = os.environ["ELASTIC_API_KEY"].strip()
elastic_url = os.environ.get("ELASTIC_URL", "").rstrip("/")

from scenario_engine import get_scenario
from elastic_config.deployer import ScenarioDeployer

print(f"Loading scenario: {scenario_id}")
scenario = get_scenario(scenario_id)
print(f"  Namespace: {scenario.namespace}")
print(f"  Name:      {scenario.scenario_name}")
print(f"  Kibana:    {kibana_url}")
print()

deployer = ScenarioDeployer(
    scenario=scenario,
    elastic_url=elastic_url,
    kibana_url=kibana_url,
    api_key=api_key,
)

_last_reported = {}

def _on_progress(progress):
    steps = progress.steps or []
    for step in steps:
        status = step.status
        name   = step.name
        detail = step.detail
        items_done  = step.items_done
        items_total = step.items_total
        if status in ("ok", "failed", "running"):
            key = (name, status, detail, items_done)
            if _last_reported.get(name) == key:
                continue
            _last_reported[name] = key
            suffix = ""
            if items_total:
                suffix = f" ({items_done}/{items_total})"
            if detail:
                suffix += f" — {detail}"
            icon = "✅" if status == "ok" else ("❌" if status == "failed" else "⏳")
            print(f"  {icon} {name}{suffix}", flush=True)

print("Starting full deploy…")
result = deployer.deploy_all(callback=_on_progress)

print()
if result.error:
    print(f"❌  Deploy finished with error: {result.error}")
    sys.exit(1)
else:
    print("✅  Deploy complete.")
    steps = result.steps or []
    failed = [s for s in steps if s.status == "failed"]
    if failed:
        print(f"  {len(failed)} step(s) had failures (non-fatal):")
        for s in failed:
            print(f"    - {s.name}: {s.detail}")
PYEOF

deactivate

echo
echo "✅  recreate-serverless.sh complete for scenario '${SCENARIO_ID}'."
echo
echo "Next steps:"
echo "  1. Open Kibana → Observability → AI Assistant to see the AI analyst agent"
echo "  2. Check Observability → Streams → logs.otel.${SCENARIO_ID} for knowledge indicators"
echo "  3. Check Observability → SLOs for the 3 auto-created SLOs"
echo "  4. (Optional) Start live telemetry:"
echo "     cd ${APP_DIR}"
echo "     KIBANA_URL=${KIBANA_URL} ELASTIC_API_KEY=${API_KEY} \\"
echo "     ACTIVE_SCENARIO=${SCENARIO_ID} OTLP_ENDPOINT=<ingest-url>:443 \\"
echo "     python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8080"
