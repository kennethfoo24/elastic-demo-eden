# SaaS / identity / cloud / EDR data — lighting up the entity-analytics rules

## Problem

The `entity-analytics` space ships **35 custom detection rules** covering a broad
SaaS/identity/cloud/EDR fleet. All 35 imported and are enabled, but a comparison against
the reference EDEN demo showed **~26 of them sat idle** — their source data streams were
empty. Only Okta, AWS CloudTrail, and Elastic Defend endpoint data were present. This was
the single biggest reason the reference demo's **Alerts page** was richer than ours.

Empty streams (now filled): `logs-crowdstrike.falcon-*` / `.alert-*`, `logs-o365.audit-*`,
`logs-google_workspace.login-*`, `logs-github.audit-*`, `logs-cisco_duo.auth-*`,
`logs-slack.audit-*`, `logs-ping_one.audit-*`, `logs-1password.signin_attempts-*`,
`logs-zscaler_zia.web-*` / `.firewall-*`, `logs-jamf_pro.events-*`,
`logs-cloudflare_logpush.firewall_event-*`, `logs-servicenow.event-*`,
`logs-sailpoint_identity_sc.events-*`, `logs-system.auth-*`, `logs-ti_abusech.malware-*`.

## Fix (`saas-identity-seeder.yaml`)

CronJob `saas-identity-seeder` (`*/15m`, namespace `security-fc`, secret
`security-fc-es-creds`) emits **schema-correct ECS events** into every empty stream,
crafted to satisfy each rule's exact query (e.g. `crowdstrike.metadata.eventType`,
`event.severity >= 7`, `event.action: "ssh_login" AND event.outcome: "failure"`). The
identity/SaaS failures are centred on the compromised user **`gbadmin`** from the
attack-range **attacker IPs** (45.83.193.150, 35.235.244.32, …), so the data reads as a
coherent **cross-SaaS credential attack** — feeding entity-risk scoring and (if an
entity-analytics AD schedule is added) Attack Discovery.

## Result — verified

One seed run lit up **all 35 rules → 664 alerts/day** in the entity-analytics alerts index
(`.alerts-security.alerts-entity-analytics`). Top firers: Failed SSH (103), Okta Failed
Login (50), Duo Denied (37), CrowdStrike Remote Response (36), Suspicious Network/Process
(34/34), Cloudflare WAF (26), CrowdStrike High-Sev Detection (26)… every previously-idle
source now produces alerts. Entity-risk scoring (Entity Store V2) is active and now
incorporates the `gbadmin` identity story.

> **NOTE — alerts land in the entity-analytics space.** These rules write to
> `.alerts-security.alerts-entity-analytics`, NOT `.alerts-security.alerts-default`. View
> them at `/s/entity-analytics/app/security/alerts`.

## Retention

Bounded by the freshness-engine `data-retention` job (30-day cleanup); the 17 SaaS
families were added to its `FAMILIES_JSON`. The seeder creates fresh docs (new ids) each
run so the rules keep producing recent alerts (rules run every 5m, 14d lookback).

## Optional next step — Attack Discovery in the entity-analytics space

The entity-analytics space has **no Attack Discovery schedule** (only the default space
does). To surface these SaaS/identity alerts as *attack campaigns* on that space's Attacks
page, create an attack-discovery schedule at `/s/entity-analytics` using the
`.anthropic-claude-4.8-opus` connector, `alertsIndexPattern: .alerts-security.alerts-entity-analytics`.
The Alerts page and entity-risk scoring are already enriched without it.

## Verify

```
# per-rule alert counts (entity-analytics space)
GET .alerts-security.alerts-entity-analytics/_search
  {"size":0,"query":{"range":{"@timestamp":{"gte":"now-1d"}}},
   "aggs":{"r":{"terms":{"field":"kibana.alert.rule.name","size":50}}}}
```
