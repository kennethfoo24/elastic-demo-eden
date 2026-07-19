# Freshness Engine + Live Sensors — operations

Implements [../specs/2026-07-19-self-sustaining-live-demo-design.md](../specs/2026-07-19-self-sustaining-live-demo-design.md).
Everything below runs in-project against the serverless Security project
`kenneth-sandbox-sec-c9cf0d` with **zero dependency on the (decommissioned) hosted
EDEN cluster**. All k8s objects use the `security-fc-es-creds` secret.

## A. Freshness Engine  (`freshness-engine.yaml`)
Keeps the resident data corpus flowing fresh forever.

| Object | Schedule | What it does |
|--------|----------|--------------|
| CronJob `data-recycler` | `*/15 * * * *` | Randomly samples the newest docs of each data family, re-timestamps across the last 6h, bulk-creates them back into the same data stream. |
| CronJob `data-retention` | `30 3 * * *` | `delete_by_query @timestamp < now-30d` per family, to bound growth. |

Families: `logs-system.security-*`, `logs-auditd_manager.auditd-*`, `logs-aws.cloudtrail-*`,
`logs-okta.system-*`, `logs-network_traffic.flow-*`, `logs-cloud_security_posture.findings-*`
(CSPM+synthetic-KSPM), `logs-qualys_vmdr.*`, `logs-tenable_io.*`, `logs-wiz.*`.

Manual run: `kubectl create job fresh-now -n security-fc --from=cronjob/data-recycler`

## B. Live KSPM on GKE  (`kspm-agent-gke.yaml`)
Elastic Agent DaemonSet in `kube-system` enrolled to Fleet policy **kspm-gke**
(CSP package, input `cloudbeat/cis_k8s`, posture=kspm, deployment=self_managed).
Produces **real** CIS-Kubernetes findings from this cluster (e.g. 2,117 findings /
run, ~356 failing) into `logs-cloud_security_posture.findings-*`.
- Enrollment token/URL are injected via the k8s secret **`kspm-fleet-enroll`** in
  `kube-system` (NOT committed): `kubectl create secret generic kspm-fleet-enroll -n kube-system --from-env-file=<file with FLEET_URL,FLEET_ENROLLMENT_TOKEN>`
- `hostPID: true` enabled for CIS node/process checks. Image pinned to `elastic-agent:9.4.3`.

## C. Live threat-intel  (`threat-intel-seeder.yaml`)
abuse.ch now requires an Auth-Key, so instead a curated feed is seeded into
`logs-ti_custom.indicator-default` (matches the rules' default `logs-ti_*`).
Includes the attack-range **C2 IOCs** (`35.235.244.32`, C2 URLs) so the live
attack beacons trip the prebuilt indicator-match rules (IP/URL/hash). CronJob
`threat-intel-seeder` (`*/30 * * * *`) re-timestamps so the panel stays populated.

## D. OS-log integrations on the 2 VMs  (Fleet package policies)
Added to the attack-range agent policies so the 6-hourly attack chains generate
telemetry through these channels too (not just Elastic Defend):
- `attack-range-linux`: **Auditd Manager** (`auditd_manager.auditd`) with execve +
  identity/priv/authlog watch rules → live Linux syscall telemetry (verified: live
  execve events captured from the attack).
- `attack-range-windows`: **System** (`system.security/application/system` event
  logs → feeds `[System Windows Security]` dashboard) + **Windows** (PowerShell
  script-block logging).

### Windows agent gotcha
The GCE Windows guest-agent can crash (Go panic) running large metadata startup
scripts, and a broken agent shows `orphaned` in Fleet. Fix = a **lightweight
re-enroll of the already-installed binary** (no 600MB re-download):
`elastic-agent.exe enroll --url=<FLEET_URL> --enrollment-token=<token> --force` then
restart the `Elastic Agent` service, delivered via `windows-startup-script-ps1` + reset.
If the guest-agent keeps crashing, recreate the VM (clean install+enroll on first boot
is the most reliable path) — the fresh agent joins `attack-range-windows` and comes up healthy.

## E. Live network capture + Threat Intelligence Utilities
- **network_traffic (Packetbeat)** package policy on `attack-range-linux`: live packet
  capture (flow/dns/tls/http/...) from the Linux VM → real network telemetry incl. the
  attack's C2 beacons, nmap sweeps, and DNS. Feeds the Network page + correlation.
  Note: the legacy Overview "Network events" widget buckets by `event.dataset`, which
  the modern network_traffic integration does not populate (it uses `data_stream.dataset`),
  so that specific widget may read 0 — the data is fully present in Security → Network,
  Discover, and detection rules.
- **ti_util (Threat Intelligence Utilities)** installed (asset-only): indicator dedup
  transform + expiration + TI dashboards, so the custom `logs-ti_*` feed is properly managed.

## F. Phishing initial-access (`phishing-seeder.yaml` + custom rule)
Closes the one kill-chain gap vs. the reference demo: the live attack scripts modelled
"phishing" only as a renamed EXE (no email event), so Attack Discovery chains started at
**Execution**. Now a custom rule (`eden-phishing-email-malicious-attachment`, T1566.001)
fires on seeded inbound phishing emails (`logs-email_security.email-default`) tied to the
same host + user (`gbadmin`) and `resume.exe` SHA256 as the downstream chain, so AD reads
the campaign end to end: **Initial Access → Execution → Defense Evasion → Persistence →
Discovery → Collection (l00t.zip) → Exfiltration (curl → C2)**. Everything from Execution
onward already fires live from the 6-hourly attack scripts. Full detail:
[phishing-initial-access.md](phishing-initial-access.md).

## G. SaaS / identity / cloud / EDR data (`saas-identity-seeder.yaml` + 35 EA rules)
The `entity-analytics` space ships 35 custom rules across a broad SaaS/identity/cloud/EDR
fleet (CrowdStrike, M365, Google Workspace, GitHub, Duo, Slack, PingOne, 1Password,
Zscaler, Jamf, Cloudflare, ServiceNow, SailPoint, SSH, threat-intel). All were enabled but
~26 sat idle for lack of data — the main reason the reference demo's Alerts page was
richer. The `saas-identity-seeder` CronJob (`*/15m`) emits schema-correct ECS events into
every empty stream, satisfying each rule's query, with the failures centred on `gbadmin`
from the attacker IPs (a cross-SaaS credential-attack story feeding entity-risk). Verified:
all 35 rules fire (664 alerts/day) into `.alerts-security.alerts-entity-analytics` (view at
`/s/entity-analytics/app/security/alerts`). Bounded by the 30-day retention job. Full
detail incl. the optional EA-space Attack-Discovery step:
[saas-identity-data.md](saas-identity-data.md).

## Data-sourcing philosophy
- EDR (Defend), live KSPM, Linux auditd, threat-intel, Windows event logs = **live sensors**.
- CSPM findings, Okta, AWS CloudTrail, Wiz/Qualys/Tenable, network flows = **recycled
  fresh** by the Freshness Engine (no live source account needed).
- All of it → detection rules → Attack Discovery (15m), spanning cloud/identity/endpoint/K8s.
