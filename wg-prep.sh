#!/usr/bin/env bash
set -euo pipefail

UNIT="wg-quick@wg0"

KEY_DIR="/etc/wireguard/keys"
WG_DIR="/etc/wireguard"
PRIV_KEY="${KEY_DIR}/wg0.key"
PUB_KEY="${KEY_DIR}/wg0.pub"
WG_CONF="${WG_DIR}/wg0.conf"
SYSCTL_CONF="/etc/sysctl.d/99-wireguard-forward.conf"

if [[ "${EUID}" -ne 0 ]]; then
  echo "### Run As Root: sudo $0 ###"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "### Installing Required Packages (Ubuntu) ###"
apt-get update -y
apt-get install -y \
  wireguard \
  iputils-ping \
  traceroute \
  net-tools \
  mtr \
  openssh-server \
  curl

echo "### Installing Docker (Official Repository) ###"

install -m 0755 -d /etc/apt/keyrings

DOCKER_GPG="/etc/apt/keyrings/docker.gpg"

if [[ ! -f "${DOCKER_GPG}" ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o "${DOCKER_GPG}"
  chmod a+r "${DOCKER_GPG}"
else
  echo "### Docker GPG Key Already Exists — Skipping Import ###"
fi

echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

echo "### Enabling Docker ###"
systemctl enable --now docker

echo "### Enable and Start SSH ###"
systemctl enable --now ssh

echo "### Changing SSH Port On Host To 2222 ###"
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_BACKUP="/etc/ssh/sshd_config.bkup.$(date +%s)"

cp "${SSH_CONFIG}" "${SSH_BACKUP}"
echo "### Backup Created At ${SSH_BACKUP} ###"

sed -i '/^#\?Port[[:space:]]\+/d' "${SSH_CONFIG}"
printf "\nPort 2222\n" >> "${SSH_CONFIG}"

if sshd -t; then
  systemctl restart sshd
  echo "### SSH Successfully Moved To Port 2222 ###"
else
  echo "### SSHD Config Test Failed — Restoring Backup ###"
  cp "${SSH_BACKUP}" "${SSH_CONFIG}"
  systemctl restart sshd || true
  exit 1
fi

echo "### Putting Customer DNS from DHCP into /etc/resolv.conf ###"
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

echo "### Create Keys Directory For WireGuard ###"
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

echo "### Generate WireGuard Keys (if missing) ###"
if [[ ! -f "${PRIV_KEY}" ]]; then
  umask 077
  wg genkey | tee "${PRIV_KEY}" | wg pubkey > "${PUB_KEY}"
  chmod 600 "${PRIV_KEY}"
  chmod 644 "${PUB_KEY}"
  echo "### Keys Generated ###"
else
  echo "### Keys Already Exist - Skipping Generation ###"
fi

read -rp "Enter this host's WireGuard IP (no CIDR, example 10.10.10.2): " WG_ADDRESS_IP
read -rp "Enter AllowedIPs network (example 192.168.1.0/24): " WG_ALLOWED_NET_CIDR
read -rp "Enter Peer Public Key: " PEER_PUBLIC_KEY
read -rp "Enter Server IP (example 1.1.1.1): " SERVER_IP
read -rp "Enter Server Port (example 7711): " SERVER_PORT

PEER_KEEPALIVE="25"
PEER_ENDPOINT="${SERVER_IP}:${SERVER_PORT}"

if [[ -z "${WG_ADDRESS_IP}" || -z "${WG_ALLOWED_NET_CIDR}" || -z "${PEER_PUBLIC_KEY}" || -z "${SERVER_IP}" || -z "${SERVER_PORT}" ]]; then
  echo "All fields are required. Exiting."
  exit 1
fi

echo "### Enable IPv4 Forwarding (runtime + persistent) ###"
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" > "${SYSCTL_CONF}"
sysctl --system >/dev/null

echo "### Writing ${WG_CONF} ###"
mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"

PRIVATE_KEY_VALUE="$(cat "${PRIV_KEY}")"

cat > "${WG_CONF}" <<EOF
[Interface]
PrivateKey = ${PRIVATE_KEY_VALUE}
Address = ${WG_ADDRESS_IP}/32

[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
Endpoint = ${PEER_ENDPOINT}
AllowedIPs = ${WG_ALLOWED_NET_CIDR}
PersistentKeepalive = ${PEER_KEEPALIVE}
EOF

chmod 600 "${WG_CONF}"

echo "### Configure Systemd Ordering ###"
DROPIN_DIR="/etc/systemd/system/${UNIT}.d"
DROPIN_FILE="${DROPIN_DIR}/override.conf"
mkdir -p "${DROPIN_DIR}"

cat > "${DROPIN_FILE}" <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
EOF

systemctl enable --now NetworkManager-wait-online.service >/dev/null 2>&1 || true
systemctl daemon-reload

echo "### Enable and Start ${UNIT} ###"
systemctl enable "${UNIT}"
systemctl restart "${UNIT}"

echo
echo "================ FINAL STATUS ================"

echo
echo "### Service Status (${UNIT}) ###"
systemctl status "${UNIT}" --no-pager || true

echo
echo "### WireGuard Tunnel Status ###"
wg show || true

echo
echo "### Interface Details (wg0) ###"
ip addr show wg0 || true

echo
echo "### Public IP (Client Outbound) ###"
PUBLIC_IP="$(curl -4 -s https://api.ipify.org || echo 'Unable to Determine')"
echo "Public Facing IP: ${PUBLIC_IP}"

echo
echo "### WireGuard Configuration Summary ###"
echo "Local Address                                     : ${WG_ADDRESS_IP}/32"
echo "Allowed IPs                                       : ${WG_ALLOWED_NET_CIDR}"
echo "Peer Public Key                                   : ${PEER_PUBLIC_KEY}"
echo "Server IP                                         : ${SERVER_IP}"
echo "Server Port                                       : ${SERVER_PORT}"
echo "Peer Endpoint                                     : ${PEER_ENDPOINT}"
echo "Persistent Keepalive                              : ${PEER_KEEPALIVE}"
echo "Client Public Key (put this on remote server)     : $(cat "${PUB_KEY}")"

echo
echo "### IP Forwarding Status ###"
sysctl net.ipv4.ip_forward

echo
echo "================================================"
echo "### WireGuard Preperation Complete ###"
echo "================================================"

echo
echo "================================================="
echo "### COPY THIS TO YOUR SERVER /etc/wireguard/wg0.conf ###"
echo "================================================="
echo
echo "[Peer]"
echo "PublicKey = $(cat "${PUB_KEY}")"
echo "AllowedIPs = ${WG_ADDRESS_IP}/32"
echo "PersistentKeepalive = ${PEER_KEEPALIVE}"
echo
echo "================================================="
