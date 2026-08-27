#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
umask 077

apt-get update
apt-get -y -o Dpkg::Options::=--force-confold upgrade
apt-get install -y wireguard-tools ufw unattended-upgrades curl iptables

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat >/etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

cat >/etc/sysctl.d/99-wireguard-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF

sysctl --system

install -d -m 700 /etc/wireguard
install -d -m 700 /etc/wireguard/users

PUBLIC_IP="$(
    curl -4fsS --max-time 5 \
        http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address \
    || curl -4fsS --max-time 10 https://api.ipify.org
)"

WAN_IF="$(ip -4 route show default | awk '{print $5; exit}')"

wg genkey >/etc/wireguard/host.key
wg pubkey </etc/wireguard/host.key >/etc/wireguard/host.pub

HOST_PRIV="$(cat /etc/wireguard/host.key)"
HOST_PUB="$(cat /etc/wireguard/host.pub)"

cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.67.69.1/24
ListenPort = 2026
PrivateKey = ${HOST_PRIV}
EOF

for i in $(seq 2 20); do
    USER="/etc/wireguard/users/user-${i}"

    wg genkey >"${USER}.key"
    wg pubkey <"${USER}.key" >"${USER}.pub"

    USER_PRIV="$(cat "${USER}.key")"
    USER_PUB="$(cat "${USER}.pub")"

    cat >>/etc/wireguard/wg0.conf <<EOF

[Peer]
PublicKey = ${USER_PUB}
AllowedIPs = 10.67.69.${i}/32
EOF

    cat >"${USER}.conf" <<EOF
[Interface]
PrivateKey = ${USER_PRIV}
Address = 10.67.69.${i}/32

[Peer]
PublicKey = ${HOST_PUB}
Endpoint = ${PUBLIC_IP}:2026
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    cat >"${USER}.wg.conf" <<EOF
[Interface]
PrivateKey = ${USER_PRIV}

[Peer]
PublicKey = ${HOST_PUB}
Endpoint = ${PUBLIC_IP}:2026
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
done

chmod 600 /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/host.key /etc/wireguard/host.pub
chmod 600 /etc/wireguard/users/*

cp /etc/ufw/before.rules /etc/ufw/before.rules.orig

{
    cat <<EOF
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.67.69.0/24 -o ${WAN_IF} -j MASQUERADE
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
-A PREROUTING -i ${WAN_IF} -p tcp --dport 80 -j DNAT --to-destination 10.67.69.2:80
-A PREROUTING -i ${WAN_IF} -p tcp --dport 443 -j DNAT --to-destination 10.67.69.2:1443
-A PREROUTING -i wg0 -d ${PUBLIC_IP}/32 -p tcp --dport 443 -j DNAT --to-destination 10.67.69.2:2443
COMMIT

EOF
    cat /etc/ufw/before.rules.orig
} >/etc/ufw/before.rules

WAN_IF="$(ip -4 route show default | awk '{print $5; exit}')"

ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 2026/udp


# DNAT: route public HTTP/HTTPS to VM (in ufw before.rules above): 80->80, 443->1443
ufw route allow in on "${WAN_IF}" out on wg0 from any to 10.67.69.2 proto tcp port 80
ufw route allow in on "${WAN_IF}" out on wg0 from any to 10.67.69.2 proto tcp port 1443

ufw allow in on wg0 from 10.67.69.0/24 to 10.67.69.1 proto tcp port 22
ufw route allow in on wg0 out on wg0 from 10.67.69.0/24 to 10.67.69.2
ufw route allow in on wg0 out on wg0 from 10.67.69.0/24 to ${PUBLIC_IP}/32 proto tcp port 443
ufw route allow in on wg0 out on "${WAN_IF}" from 10.67.69.2 to 0.0.0.0/0

ufw --force enable

systemctl enable --now wg-quick@wg0

sync
systemctl reboot