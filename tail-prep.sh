#!/bin/bash

# Must be root
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: MUST RUN AS ROOT"
  exit 1
fi

read -rp "Enter hostname (VHID): " VHID
read -rp "Enter Headscale login server URL (ex: https://headscale.example.com): " LOGIN_SERVER
read -s -p "Enter auth key (will not display on screen): " AUTH_KEY
echo ""

if [[ -z "$VHID" || -z "$LOGIN_SERVER" || -z "$AUTH_KEY" ]]; then
  echo "ERROR: VHID, LOGIN_SERVER, and AUTH_KEY cannot be empty."
  exit 1
fi

pause() { sleep 2; }
header() { echo ""; echo "### $1 ###"; pause; }

header "System Setup"
hostnamectl hostname "$VHID"
apt update -y && apt upgrade -y
apt install -y curl wget htop mtr jq
pause

header "Install Tailscale (if needed)"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
pause

header "Enable + Start tailscaled"
systemctl enable tailscaled
systemctl start tailscaled
pause

header "Bring Up Tailscale"

# Normalize login-server (auto-add https:// if missing)
case "$LOGIN_SERVER" in
  http://*|https://*) ;;
  *) LOGIN_SERVER="https://$LOGIN_SERVER" ;;
esac
echo "Login server: $LOGIN_SERVER"

echo "Bringing up Tailscale (will timeout after 10s if stuck)..."
if ! tailscale status >/dev/null 2>&1; then
    tailscale up \
      --login-server="$LOGIN_SERVER" \
      --authkey="$AUTH_KEY" \
      --hostname "$VHID" \
      --accept-routes \
      --accept-dns=false
else
    tailscale up \
      --login-server="$LOGIN_SERVER" \
      --hostname "$VHID" \
      --accept-routes \
      --accept-dns=false
fi

pause

header "Routes Learned (non-/32)"
tailscale status --json | jq -r '
  .Peer[]
  | {host: .HostName, routes: ([.AllowedIPs[] | select(endswith("/32")|not)])}
  | select(.routes | length > 0)
  | "\(.host): \(.routes | join(", "))"
'
pause

TARGET_IP="100.64.0.1"
header "Ping Headscale ($TARGET_IP)"
if ping -c 3 -W 5 "$TARGET_IP" >/dev/null; then
  echo "SUCCESS: Connectivity to $TARGET_IP Established"
else
  echo "FAILURE: Cannot reach $TARGET_IP"
fi

pause

echo ""
echo "PREPARTION COMPLETE"
 
