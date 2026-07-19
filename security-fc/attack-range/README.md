# Attack Range — live Elastic Defend endpoints for Attack Discovery

Two GCE VMs in project `elastic-sa` (zone `asia-southeast1-c`) run **Elastic Agent
+ Elastic Defend (detect mode)** enrolled to the serverless Security project
(`kenneth-sandbox-sec-c9cf0d`). Scripted, safe-by-design attack chains generate
real endpoint telemetry + MITRE detections that **Attack Discovery** correlates
into campaigns — the live counterpart to the recycled `eden-alerts` corpus.

## Hosts
| VM | OS | Role |
|----|----|------|
| `kenneth-defend-ubuntu`  | Ubuntu 22.04  | SSH-exfil + Linux priv-esc chain |
| `kenneth-defend-windows` | Windows 2022  | phishing -> LOLBin -> persistence -> recon |

Both attacks share C2 IOCs (Slack webhook `35.235.244.32`, `api.telegram.org`,
`l00t.zip`) so Attack Discovery can link them as a **cross-platform campaign**.

## Fleet config (already applied)
- Agent policies `attack-range-linux` / `attack-range-windows`, each with Elastic
  Defend (all protections = **detect**) + System integration.
- 980 detection rules enabled (Elastic Defend + Endgame + Threat Detection tags).
- Enrollment tokens + Fleet URL live in `../../.attack-range.env` (git-ignored).

## Provisioning (idempotent)
```bash
source .attack-range.env   # FLEET_URL, LINUX_ENROLL, WINDOWS_ENROLL
LABELS="division=field,org=sa,team=apj_asean,project=kennethfoo,keep-until=<date>,purpose=attack-range"
# Linux
gcloud compute instances create kenneth-defend-ubuntu --zone=asia-southeast1-c \
  --machine-type=e2-standard-2 --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud \
  --labels=$LABELS --metadata=fleet_url=$FLEET_URL,enroll_token=$LINUX_ENROLL,agent_version=9.4.0 \
  --metadata-from-file=startup-script=startup-linux.sh
# Windows
gcloud compute instances create kenneth-defend-windows --zone=asia-southeast1-c \
  --machine-type=e2-standard-2 --image-family=windows-2022 --image-project=windows-cloud \
  --labels=$LABELS --metadata=fleet_url=$FLEET_URL,enroll_token=$WINDOWS_ENROLL,agent_version=9.4.0 \
  --metadata-from-file=windows-startup-script-ps1=startup-windows.ps1
```

## Running the attacks
- **Linux:** `gcloud compute scp attack-linux.sh kenneth-defend-ubuntu:/tmp/ --tunnel-through-iap`
  then `gcloud compute ssh kenneth-defend-ubuntu --tunnel-through-iap --command="sudo bash /tmp/attack-linux.sh"`.
- **Windows** (no sshd): build a one-shot runner (guard + ASCII-only body of
  `attack-windows.ps1`), push as `windows-startup-script-ps1`, then
  `gcloud compute instances reset kenneth-defend-windows`. Clear the marker
  `C:\attack-range\attack-done` to re-fire. See `run-attack-windows.sh`.

  Gotchas learned: set `$ProgressPreference='SilentlyContinue'` (else the ~600MB
  agent download crawls); keep the script **pure ASCII** (an em-dash broke the
  metadata script parser); the marker makes it run once per boot.

## Attack Discovery
- Schedule **"Attack Range Correlation"** (id `b2886362-...`) runs every 15m
  against `.alerts-security.alerts-default` using the preconfigured
  `Anthropic-Claude-Sonnet-4-6` inference connector — no setup needed.
- Or run on demand: Security -> Attack Discovery -> pick the connector -> Generate.

## Teardown
```bash
gcloud compute instances delete kenneth-defend-ubuntu kenneth-defend-windows \
  --zone=asia-southeast1-c --quiet
```
