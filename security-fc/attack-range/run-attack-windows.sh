#!/usr/bin/env bash
# Fire (or re-fire) the Windows attack chain on kenneth-defend-windows.
# Windows GCE images have no sshd, so we drive the attack via a one-shot
# metadata startup-script guarded by a marker file, then reset the VM.
#
# Requirements learned the hard way and encoded below:
#   - pure ASCII (a Unicode em-dash broke the PowerShell metadata parser)
#   - $ProgressPreference=SilentlyContinue is set in the provisioning script
#   - marker C:\attack-range\attack-done makes it run exactly once per boot
set -euo pipefail
PROJECT=elastic-sa; ZONE=asia-southeast1-c
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$(mktemp /tmp/win-attack-runner.XXXX.ps1)"

python3 - "$HERE/attack-windows.ps1" "$RUNNER" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
guard = ('$ErrorActionPreference = "Continue"\n'
         '$ProgressPreference = "SilentlyContinue"\n'
         'New-Item -ItemType Directory -Force -Path "C:\\attack-range" | Out-Null\n'
         'if (Test-Path "C:\\attack-range\\attack-done") { exit 0 }\n'
         'Start-Sleep -Seconds 90\n')
body = [l.rstrip("\n") for l in open(src, encoding="utf-8")
        if l.strip() and not l.strip().startswith("#")]
footer = '\nWrite-Output "done" | Out-File "C:\\attack-range\\attack-done"\n'
txt = (guard + "\n".join(body) + "\n" + footer)
txt = txt.encode("ascii", "replace").decode("ascii").replace("?", "-")  # force ASCII
open(out, "w").write(txt)
PY

gcloud compute instances add-metadata kenneth-defend-windows --project="$PROJECT" --zone="$ZONE" \
  --metadata-from-file=windows-startup-script-ps1="$RUNNER"
gcloud compute instances reset kenneth-defend-windows --project="$PROJECT" --zone="$ZONE"
echo "Windows attack fired; chain executes ~90s after boot. Check Security -> Alerts."
