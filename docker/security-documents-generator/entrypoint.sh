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
exec yarn start "$@"
