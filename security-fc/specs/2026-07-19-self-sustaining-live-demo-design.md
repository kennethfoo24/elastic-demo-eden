# Self-sustaining, live-first Security demo — design

**Date:** 2026-07-19
**Target project:** serverless Security `kenneth-sandbox-sec-c9cf0d` (ap-southeast-1)
**Status:** approved design → implementation pending

## Goal

Turn the Security demo into a comprehensive, always-fresh environment covering **EDR,
SIEM (OS + cloud/identity), CSPM, KSPM** that runs indefinitely with **zero dependency on
the decommissioned hosted EDEN cluster**, and feeds meaningful, correlatable alerts into
**Attack Discovery**.

## Governing principle (applies to every data category)

1. **Keep** the existing reindexed corpus already resident in the serverless project.
2. **Cut the cord** — no reliance on the hosted `security-fc-unified` cluster (now shut down).
3. **Flow fresh** — every category continuously emits recent data on its own, in-project.
4. **Add real sensors on top** where the environment allows (2 GCE VMs, the GKE cluster).

Dependency on hosted was audited and confirmed zero before decommission: serverless cannot
form a remote link (`_remote/info` → 410), all transforms read local indices, every family
is resident, and no k8s job pulled from hosted.

## Architecture

Two subsystems plus the existing correlation layer.

### A. Freshness Engine — "keep the data, cut the cord, keep it fresh"

Replaces the one-time `reindex-from-hosted` with an in-project recycler. A set of GKE
CronJobs (namespace `security-fc`), one containerized script parametrized per data family:

1. Read a rolling sample of the **newest** docs already in the serverless project for the family.
2. Rewrite `@timestamp` (+ `event.ingested`) spread across the current window; drop `_id`.
3. Bulk-index back into the **same data stream** via an ingest pipeline (`op_type=create`).
4. **Retention step:** delete docs older than the demo window (30 days) to bound growth.

Uses genuinely realistic data (real field values/entities), sidesteps the data-stream-template
error that broke the old `generate-events`, and needs no hosted cluster. Same pattern as the
existing `alert-recycler`, generalized to raw data. For CSPM, also nudge the score transform so
gauges stay live.

**Cadence:** every 15–30 min per family.

**Families (all data streams, resident counts as of design):**

| Family | Data stream pattern | Resident docs |
|--------|--------------------|--------------|
| SIEM — Windows security | `logs-system.security-*` | 195,872 |
| SIEM — Linux auditd | `logs-auditd_manager.auditd-*` | 1,339,489 |
| SIEM — AWS CloudTrail | `logs-aws.cloudtrail-*` | 24,908 |
| SIEM — Okta identity | `logs-okta.system-*` | 16,558 |
| Network flows | `logs-network_traffic.flow-*` | 6,434,456 |
| CSPM/KSPM findings | `logs-cloud_security_posture.findings-*` | 34,700 |
| Vuln — Qualys | `logs-qualys_vmdr.*` | 20,820 |
| Vuln — Tenable | `logs-tenable_io.*` | 20,820 |
| Vuln/CDR — Wiz | `logs-wiz.*` | 41,640 |

> Sampling ratio and per-family batch sizes are tuned so recent-time windows (last 3h/24h)
> always populate without unbounded growth. Network flow (6.4M) samples a small % per cycle.

### B. Live sensors — real telemetry on top

| Sensor | Where | Produces |
|--------|-------|----------|
| **KSPM** (Cloud Security Posture, KSPM input) | Agent on the existing **GKE cluster** | Real CIS-K8s findings + misconfig alerts from the actual cluster; overtakes synthetic `cis_k8s` |
| **Windows OS logs** | Repair orphaned agent, add Windows integration on `kenneth-defend-windows` | Live 4624/4625/4688/4720 → SIEM logon/lockout/priv rules; fixes empty `[System Windows Security]` dashboard |
| **Linux OS logs** | Auditd Manager (+ Sysmon for Linux) on `kenneth-defend-ubuntu` | Live execve/auditd beyond Defend |
| **Threat intel** | AbuseCH feeds (URLhaus/MalwareBazaar/ThreatFox), agent on GKE | Populates Threat Intelligence panel; enables indicator-match rules against live endpoint/network data |

### C. Correlation layer (already live — unchanged)

Detection rules (980) → alerts → **Attack Discovery** schedule (every 15m, Claude Sonnet).
Plus the `alert-recycler` (curated EDEN campaigns, every 6h). With A+B, a single campaign can
span **cloud misconfig (CSPM) → identity (Okta) → endpoint (EDR) → K8s escalation (live KSPM)
→ exfil**, across real and fresh-recycled layers.

## Where it all runs

- **GKE `security-fc`:** Freshness-Engine CronJobs, live KSPM agent, threat-intel agent.
- **The 2 GCE VMs:** OS-log integrations via Fleet policy update (+ Windows agent repair).
- **Serverless project:** the durable home for all data; Attack Discovery + rules.

## Engineering decisions

- **Recycle real docs forward** over synthetic generators — faithful data; avoids the
  data-stream-template failure that broke `generate-events`.
- **30-day retention** on recycled families to bound index growth.
- **Deterministic teardown via Cloud API `_shutdown`** (not `beden delete`, whose name lookup
  was unreliable) — already used to decommission the 3 hosted clusters.

## Verification

- Each recycled family shows fresh docs inside a last-3h window after one cycle; index size
  stays bounded across cycles (retention working).
- Live KSPM: `logs-cloud_security_posture.findings-*` gains docs with the real GKE cluster id /
  `cis_gke` results; misconfig alerts appear.
- Windows agent `online` (not orphaned); `[System Windows Security]` dashboard populates;
  live 4625/4688 events in Discover.
- Linux auditd events present; threat-intel indicators > 0 and an indicator-match rule fires.
- Attack Discovery produces a cross-layer campaign.

## Out of scope

- Live CSPM against GCP `elastic-sa` (kept synthetic + auto-scored, per decision).
- Live Okta/Wiz/Qualys/Tenable (no source accounts; kept fresh via the Freshness Engine).
- The `eden-o11y-metrics` Observability demo (separate).
