# Phishing initial-access step — closing the kill-chain gap

## Problem

Attack Discovery in the serverless project produced strong campaigns
(cross-platform C2 kill chains, resume.exe / update.exe DLL side-load chains), but
they started at **Execution** and lit up fewer MITRE stages than the reference EDEN
demo's "Phishing to Recon and Exfiltration", which begins with an inbound **phishing
email** (Initial Access).

Root cause: the live attack scripts model "phishing" only as a renamed EXE
(`Copy-Item whoami.exe resume.exe`). There is **no email event**, so
`event.category:email` = 0 and nothing fires an Initial-Access alert. Everything
downstream already fires live — mshta/certutil/rundll32 execution, registry
persistence, discovery, `l00t.zip` collection, and curl → C2 exfiltration.

## Fix (two parts)

### 1. Custom detection rule (one-time, via Kibana API)

[../detection-rules/phishing-email-malicious-attachment.json](../detection-rules/phishing-email-malicious-attachment.json)
— a query rule (`rule_id: eden-phishing-email-malicious-attachment`) that fires on
inbound email carrying an `*.exe` attachment, mapped to **T1566.001 Spearphishing
Attachment (Initial Access)**, severity high. Create/update it:

```bash
KB=<kibana-url>; KEY=<api-key>
curl -s -X POST "$KB/api/detection_engine/rules" \
  -H "Authorization: ApiKey $KEY" -H 'kbn-xsrf: true' -H 'x-elastic-internal-origin: true' \
  -H 'Content-Type: application/json' \
  --data-binary @security-fc/detection-rules/phishing-email-malicious-attachment.json
# already exists? swap POST for PUT to update.
```
`from: now-370m` + `interval: 5m` means it catches email events timestamped anywhere
in the last ~6h, so it stays robust against the freshness re-timestamping window.

### 2. Phishing-email seeder (`phishing-seeder.yaml`)

CronJob `phishing-seeder` (`*/15m`, namespace `security-fc`, secret
`security-fc-es-creds`) seeds fresh ECS `email.*` events into
`logs-email_security.email-default`. Each email is tied to the **same host + user
(`gbadmin`) and the same `resume.exe` SHA256** as the downstream execution alerts, so
Attack Discovery correlates the Initial-Access alert onto the existing resume.exe
campaign. Hosts covered: `xdr-siem-windows-2022-ds`, `idc-forrester-cdr-windows`,
`kenneth-defend-windows`.

## Result

The rule fires one Initial-Access alert per host (`user.name: gbadmin`,
subject "Please find attached the resume"). Attack Discovery then reads the completed
chain end to end:

**Initial Access (phishing email) → Execution (mshta/resume.exe) → Defense Evasion
(certutil/rundll32) → Persistence (Run key) → Discovery → Collection (l00t.zip) →
Exfiltration (curl → C2 35.235.244.32)** — matching the reference demo's storyline.

## Verify

```
# email events present
GET logs-email_security.email-*/_count  {"query":{"term":{"event.category":"email"}}}
# initial-access alerts firing
GET .alerts-security.alerts-default/_search
  {"query":{"term":{"kibana.alert.rule.rule_id":"eden-phishing-email-malicious-attachment"}}}
```
Then trigger the Attack Discovery "Hourly" schedule (Security → Attack Discovery →
run, or `_run_soon` on the attack-discovery alerting rule) and confirm the newest
discovery for `gbadmin` now includes the phishing email as its first step.
