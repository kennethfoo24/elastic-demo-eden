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

## Data-sourcing philosophy
- EDR (Defend), live KSPM, Linux auditd, threat-intel, Windows event logs = **live sensors**.
- CSPM findings, Okta, AWS CloudTrail, Wiz/Qualys/Tenable, network flows = **recycled
  fresh** by the Freshness Engine (no live source account needed).
- All of it → detection rules → Attack Discovery (15m), spanning cloud/identity/endpoint/K8s.
