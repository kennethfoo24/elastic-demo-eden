#!/usr/bin/env bash
# Renders config.json from env vars, then runs the generator CLI.
# Required env: ES_URL, KIBANA_URL, ES_API_KEY
set -euo pipefail

: "${ES_URL:?Set ES_URL}"
: "${KIBANA_URL:?Set KIBANA_URL}"
: "${ES_API_KEY:?Set ES_API_KEY}"

cat > /app/config.json <<EOF
{
  "elastic": { "node": "${ES_URL}", "apiKey": "${ES_API_KEY}" },
  "kibana": { "node": "${KIBANA_URL}", "apiKey": "${ES_API_KEY}" },
  "serverless": true,
  "eventIndex": "${EVENT_INDEX:-logs-testlogs-default}"
}
EOF

cd /app
RC=0
yarn start "$@" || RC=$?

# The generator stamps alerts with a fixed 2023-04-11 date. Rewrite any of its
# alerts still carrying pre-2024 timestamps to now, and tag them XDR so the
# daily update-alerts-timestamp workflow keeps rolling them forward.
if [[ "${1:-}" == "generate-alerts" ]]; then
  NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  curl -s -X POST "${ES_URL}/.alerts-security.alerts-default/_update_by_query?conflicts=proceed&refresh=true" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"script\": {
        \"lang\": \"painless\",
        \"source\": \"ctx._source['kibana.alert.last_detected'] = params.t; ctx._source['kibana.alert.original_time'] = params.t; ctx._source['kibana.alert.start'] = params.t; if (!ctx._source.containsKey('kibana.alert.workflow_tags')) { ctx._source['kibana.alert.workflow_tags'] = new ArrayList(); } if (!ctx._source['kibana.alert.workflow_tags'].contains('XDR')) { ctx._source['kibana.alert.workflow_tags'].add('XDR'); }\",
        \"params\": {\"t\": \"${NOW}\"}
      },
      \"query\": {\"range\": {\"kibana.alert.last_detected\": {\"lt\": \"2024-01-01\"}}}
    }" | head -c 300
  echo ""
fi
exit $RC
