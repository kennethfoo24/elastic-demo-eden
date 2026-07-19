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

## Automatic execution — every 6 hours (no manual refresh)
Both hosts self-run their attack chain every 6 hours via an on-VM scheduler, so
the demo stays continuously fresh with zero intervention:
- **Linux:** system cron `/etc/cron.d/attack-range` -> `0 */6 * * *` runs
  `/opt/attack-range/attack-linux.sh`. Uses `/etc/cron.d` (not the root user
  crontab) so the attack's own `crontab -r` step can't remove the scheduler.
- **Windows:** Scheduled Task **`AttackRange`** (SYSTEM, RunLevel Highest) with a
  6-hour repetition interval runs `C:\attack-range\attack-windows.ps1`. Installed
  by `startup-windows-scheduled.ps1`, which also (idempotently) installs the agent
  and writes the attack body from the `attack_script` instance-metadata key.

Cadence: Linux fires on the clock (00/06/12/18 UTC); Windows every 6h from task
registration. Combined with the alert recycler this gives a steady stream of live
MITRE alerts for Attack Discovery around the clock.

## Running an attack on demand (manual)
- **Linux:** `gcloud compute ssh kenneth-defend-ubuntu --tunnel-through-iap --command="sudo /opt/attack-range/attack-linux.sh"`
- **Windows:** `gcloud compute ssh` has no sshd; trigger the task remotely by
  resetting (startup re-runs it) or use `run-attack-windows.sh` for a one-shot run.

Gotchas learned: set `$ProgressPreference='SilentlyContinue'` (else the ~600MB
agent download crawls); keep metadata PowerShell **pure ASCII** (an em-dash broke
the parser through three boots); pass the attack body via the `attack_script`
metadata key rather than inlining it in the startup script.

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
