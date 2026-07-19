#!/usr/bin/env bash
# GCE startup script for the Linux attack-range endpoint (xdr-ubuntu-instance).
# Installs Elastic Agent, enrolls to the serverless Fleet with Elastic Defend
# (detect mode), and stages the attack-emulation scripts under /opt/attack-range.
# Fleet URL + enrollment token are passed as instance metadata (fleet_url, enroll_token).
set -euxo pipefail

FLEET_URL="$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/fleet_url)"
ENROLL="$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/enroll_token)"
AGENT_VER="$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/agent_version)"
: "${AGENT_VER:=9.4.0}"

# Demo hostname so alerts read as the attack-range endpoint
hostnamectl set-hostname kenneth-defend-ubuntu || true

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl tar nmap net-tools zip

cd /opt
curl -fsSL -o elastic-agent.tar.gz \
  "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${AGENT_VER}-linux-x86_64.tar.gz"
tar xzf elastic-agent.tar.gz
cd "elastic-agent-${AGENT_VER}-linux-x86_64"

./elastic-agent install -f \
  --url="${FLEET_URL}" \
  --enrollment-token="${ENROLL}"

# Stage attack scripts (delivered separately via SCP or metadata); mark range ready
mkdir -p /opt/attack-range
echo "attack-range linux ready $(date -u)" > /opt/attack-range/READY
