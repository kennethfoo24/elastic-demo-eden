# Security FC — self-sustaining live demo (operations)

Everything here runs **in-project** against the serverless Security project
`kenneth-sandbox-sec-c9cf0d`, with **zero dependency on the decommissioned hosted EDEN
cluster**. Design: [../specs/2026-07-19-self-sustaining-live-demo-design.md](../specs/2026-07-19-self-sustaining-live-demo-design.md).

All GKE objects live in namespace `security-fc` and read Elasticsearch creds from the
secret **`security-fc-es-creds`** (`ES_URL`, `ES_API_KEY`) — except the KSPM agent, which
uses **`kspm-fleet-enroll`** in `kube-system`. Neither secret is committed.

## Components

### Data engines — GKE CronJobs (`kubectl apply -f <file>`)

| File | CronJob(s) | Schedule | Produces |
|------|-----------|----------|----------|
| `freshness-engine.yaml` | `data-recycler` / `data-retention` | `*/15m` / daily | Recycles the resident corpus fresh (samples newest docs, re-timestamps, re-indexes). Retention deletes `@timestamp < now-30d` across all recycled + seeded families. |
| `saas-identity-seeder.yaml` | `saas-identity-seeder` | `*/15m` | Schema-correct ECS events for 17 SaaS/identity/cloud/EDR streams → lights up the 35 entity-analytics rules. |
| `phishing-seeder.yaml` | `phishing-seeder` | `*/15m` | Inbound phishing emails (`logs-email_security.email-default`) → the Initial-Access step of the endpoint kill chain. |
| `threat-intel-seeder.yaml` | `threat-intel-seeder` | `*/30m` | Custom TI indicators into `logs-ti_custom.indicator-default`, incl. the attack-range C2 IOCs (`35.235.244.32`, C2 URLs). |
| `generator-cronjobs.yaml` | `generate-alerts` | **suspended** | Legacy synthetic-alert generator. Kept for reference, `suspend: true`. (`generate-events` was deleted — it was a no-op.) |

Manual one-off run: `kubectl create job <name>-now -n security-fc --from=cronjob/<cronjob>`

### Live sensors

| File / source | What | Produces |
|---------------|------|----------|
| `kspm-agent-gke.yaml` | Elastic Agent DaemonSet in `kube-system`, Fleet policy **kspm-gke** (CSP `cloudbeat/cis_k8s`, posture=kspm). Image `elastic-agent:9.4.3`, `hostPID: true`. | Real CIS-Kubernetes findings (~2,117/run, ~356 failing) → `logs-cloud_security_posture.findings-*` |
| Fleet policies on the 2 attack-range VMs (managed in Fleet, not in this repo) | `attack-range-linux`: Auditd Manager + network_traffic (Packetbeat). `attack-range-windows`: System + Windows (PowerShell) event logs. Plus Elastic Defend on both. | Live endpoint / syscall / network / Windows-event telemetry from the 6-hourly attack chains |

### Detection rule + Attack Discovery (created via API, not k8s)

- **Phishing rule** — [../detection-rules/phishing-email-malicious-attachment.json](../detection-rules/phishing-email-malicious-attachment.json)
  (`rule_id: eden-phishing-email-malicious-attachment`, T1566.001). Import:
  ```bash
  curl -s -X POST "$KB/api/detection_engine/rules" \
    -H "Authorization: ApiKey $KEY" -H 'kbn-xsrf: true' -H 'x-elastic-internal-origin: true' \
    -H 'Content-Type: application/json' \
    --data-binary @security-fc/detection-rules/phishing-email-malicious-attachment.json
  ```
- **Entity-analytics Attack Discovery** — schedule `Hourly - Entity Analytics`. Create via
  the **dedicated schedules API** (the raw alerting API fails at run time with
  *"anonymization settings … not allow any fields"*):
  ```bash
  curl -s -X POST "$KB/s/entity-analytics/api/attack_discovery/schedules" \
    -H "Authorization: ApiKey $KEY" -H 'kbn-xsrf: true' -H 'x-elastic-internal-origin: true' \
    -H 'Content-Type: application/json' -d '{
      "name":"Hourly - Entity Analytics",
      "params":{"alerts_index_pattern":".alerts-security.alerts-entity-analytics",
        "api_config":{"connectorId":".anthropic-claude-4.8-opus-chat_completion","actionTypeId":".inference","name":"Anthropic Claude Opus 4.8"},
        "end":"now","query":{"query":"","language":"kuery"},"filters":[],"size":500,"start":"now-24h"},
      "schedule":{"interval":"1h"},"actions":[],"enabled":true}'
  ```

## The attack story (what the demo shows)

The 6-hourly attack scripts + the seeders produce one correlated, cross-layer campaign
that Attack Discovery reads end to end:

**Initial Access** (phishing email → `resume.exe`) → **Execution** (mshta/certutil) →
**Defense Evasion** (rundll32/`cdnver.dll`) → **Persistence** (Run key) → **Discovery**
(nmap) → **Collection** (`l00t.zip`) → **Exfiltration** (curl → C2 `35.235.244.32`),
across Windows + Linux hosts sharing the C2. In parallel, the SaaS/identity data drives an
**Identity Takeover** campaign (MFA-fatigue / Duo fraud → O365 forwarding → Slack/GitHub
abuse) on the same `gbadmin` account, correlated with CrowdStrike Falcon on linked hosts.

## Data-sourcing model

- **Live sensors:** Elastic Defend, KSPM (GKE), Linux auditd, Windows event logs,
  network_traffic, custom threat-intel.
- **Recycled fresh** (Freshness Engine, no live account needed): Windows security, AWS
  CloudTrail, Okta, network flows, CSPM findings, Qualys/Tenable/Wiz.
- **Seeded fresh** (SaaS/identity + phishing seeders): CrowdStrike, M365, Google Workspace,
  GitHub, Duo, Slack, PingOne, 1Password, Zscaler, Jamf, Cloudflare, ServiceNow, SailPoint,
  SSH, ti_abusech, phishing email.
- All → detection rules (default + entity-analytics spaces) → Attack Discovery (hourly, per
  space).

## Current verified state (2026-07-19)

| Check | State |
|-------|-------|
| Data streams | 21 healthy — 4 pre-existing + 17 seeded, all flowing fresh |
| entity-analytics rules | **35/35 firing**, ~1,000 alerts/day → `.alerts-security.alerts-entity-analytics` (view at `/s/entity-analytics/app/security/alerts`) |
| default-space alerts | ~800/day |
| Attack Discovery — default | `Hourly` — enabled, ok |
| Attack Discovery — entity-analytics | `Hourly - Entity Analytics` — enabled, ok |
| Seeder CronJobs | `saas-identity-seeder`, `phishing-seeder` (`*/15m`), `threat-intel-seeder` (`*/30m`), `data-recycler` (`*/15m`), `data-retention` (daily) |
| Dependency on hosted cluster | none |

## Operational notes

- **Alerts land per space.** entity-analytics rules write to
  `.alerts-security.alerts-entity-analytics`, not the `-default` index — check the right
  index/space when verifying.
- **Windows agent gotcha.** The GCE Windows guest-agent can crash (Go panic) on large
  metadata startup scripts, leaving the agent `orphaned` in Fleet. Fastest fix is a
  lightweight re-enroll of the installed binary
  (`elastic-agent.exe enroll --url=<FLEET_URL> --enrollment-token=<token> --force` + restart
  the service). If it keeps crashing, recreate the VM — a clean install+enroll on first boot
  is the most reliable path.
- **Legacy "Network events" widget** buckets by `event.dataset`; the modern
  network_traffic integration populates `data_stream.dataset`, so that one Overview widget
  may read 0 while the data is fully present in Security → Network, Discover, and rules.
