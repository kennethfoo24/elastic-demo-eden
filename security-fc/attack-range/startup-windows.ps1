# GCE windows-startup-script-ps1 for the Windows attack-range endpoint
# (elastic-defend-endpoint). Installs Elastic Agent, enrolls to serverless Fleet
# with Elastic Defend (detect mode). Fleet URL + token come from instance metadata.
$ErrorActionPreference = "Stop"
# Progress bar makes Invoke-WebRequest 10-50x slower on a ~600MB download; disable it.
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Skip if the agent is already installed (idempotent across reboots)
if (Test-Path "C:\Program Files\Elastic\Agent\elastic-agent.exe") { exit 0 }

function Meta($k) {
  Invoke-RestMethod -Headers @{'Metadata-Flavor'='Google'} `
    -Uri "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$k"
}

$FleetUrl = Meta "fleet_url"
$Enroll   = Meta "enroll_token"
$Ver      = Meta "agent_version"
if (-not $Ver) { $Ver = "9.4.0" }

# Demo hostname so alerts read as the attack-range endpoint
try { Rename-Computer -NewName "kenneth-defend-windows" -Force } catch {}

$dir = "C:\elastic"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Set-Location $dir

$zip = "elastic-agent-$Ver-windows-x86_64.zip"
Invoke-WebRequest -Uri "https://artifacts.elastic.co/downloads/beats/elastic-agent/$zip" -OutFile "$dir\$zip"
Expand-Archive -Path "$dir\$zip" -DestinationPath $dir -Force

$agentDir = "$dir\elastic-agent-$Ver-windows-x86_64"
Set-Location $agentDir
& ".\elastic-agent.exe" install -f --url="$FleetUrl" --enrollment-token="$Enroll"

New-Item -ItemType Directory -Force -Path "C:\attack-range" | Out-Null
"attack-range windows ready $(Get-Date -Format o)" | Out-File "C:\attack-range\READY"
