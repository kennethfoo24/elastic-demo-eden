$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force -Path "C:\attack-range" | Out-Null

# 1) Ensure Elastic Agent installed (idempotent)
if (-not (Test-Path "C:\Program Files\Elastic\Agent\elastic-agent.exe")) {
  $md = "http://metadata.google.internal/computeMetadata/v1/instance/attributes"
  $h  = @{'Metadata-Flavor'='Google'}
  $FleetUrl = Invoke-RestMethod -Headers $h -Uri "$md/fleet_url"
  $Enroll   = Invoke-RestMethod -Headers $h -Uri "$md/enroll_token"
  $Ver = "9.4.0"
  Rename-Computer -NewName "kenneth-defend-windows" -Force -ErrorAction SilentlyContinue
  $zip = "elastic-agent-$Ver-windows-x86_64.zip"
  Invoke-WebRequest -Uri "https://artifacts.elastic.co/downloads/beats/elastic-agent/$zip" -OutFile "C:\elastic\$zip"
  Expand-Archive -Path "C:\elastic\$zip" -DestinationPath "C:\elastic" -Force
  & "C:\elastic\elastic-agent-$Ver-windows-x86_64\elastic-agent.exe" install -f --url="$FleetUrl" --enrollment-token="$Enroll"
}

# 2) Write the attack script from metadata to disk
$md = "http://metadata.google.internal/computeMetadata/v1/instance/attributes"
$attack = Invoke-RestMethod -Headers @{'Metadata-Flavor'='Google'} -Uri "$md/attack_script"
Set-Content -Path "C:\attack-range\attack-windows.ps1" -Value $attack -Encoding ASCII

# 3) Register a Scheduled Task to run the attack every 6 hours (as SYSTEM)
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\attack-range\attack-windows.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 6)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "AttackRange" -Action $action -Trigger $trigger -Principal $principal -Force
Start-ScheduledTask -TaskName "AttackRange"
"scheduled $(Get-Date -Format o)" | Out-File "C:\attack-range\scheduled"
