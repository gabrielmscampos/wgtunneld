#!/usr/bin/env bash

create_wireguard_config() {
  local wireguard_ip="${WIREGUARD_IP}"
  local wireguard_port="${WIREGUARD_PORT:-51820}"
  local wireguard_mtu="${WIREGUARD_MTU:-1280}"

  # Server keys
  local server_private="$(wg genkey)"
  local server_public="$(echo -n "${server_private}" | wg pubkey)"

  # Peer keus
  local peer_private="$(wg genkey)"
  local peer_public="$(echo -n "${peer_private}" | wg pubkey)"

  # Server configuration
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $server_private
Address = 10.10.10.254/32
ListenPort = $wireguard_port
MTU = $wireguard_mtu
SaveConfig = false

[Peer]
PublicKey = $peer_public
AllowedIPs = 10.10.10.1/32
EOF

  # Peer configuration
  cat > /etc/wireguard/peer.conf <<EOF
[Interface]
PrivateKey = $peer_private
Address = 10.10.10.1/32
MTU = $wireguard_mtu
SaveConfig = false

[Peer]
PublicKey = $server_public
Endpoint = $wireguard_ip:$wireguard_port
AllowedIPs = 10.10.10.254/32
PersistentKeepalive = 25
EOF
}

create_socat_services() {
  # Kill any old socat processes
  pkill socat 2>/dev/null || true

  # Read each forwarding rule from YAML
  mapfile -t forward < <(yq e -o=tsv '.forward[] | [.sourceIp, .sourcePort, .destinationPort]' /etc/forwarding.yaml)
  
  for f in "${forward[@]}"; do
    IFS=$'\t' read -r sourceIp sourcePort destinationPort <<< "$f"
  
    src_port=${sourcePort%/*}
    src_proto=${sourcePort#*/}
    dst_port=${destinationPort%/*}
    dst_proto=${destinationPort#*/}

    if [ "$src_proto" = "tcp" ]; then
      socat TCP-LISTEN:$src_port,bind=$sourceIp,fork TCP:10.10.10.1:$dst_port &
    elif [ "$src_proto" = "udp" ]; then
      socat UDP-LISTEN:$src_port,bind=$sourceIp,fork UDP:10.10.10.1:$dst_port &
    fi
  done
}

stop_tunnel() {
  echo "$(date): Shutting down Wireguard"
  timeout 5 wg-quick down wg0

  exit 0
}

main() {
  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "$(date): Creating wireguard config, check the config dir for the client config"
    create_wireguard_config
  fi

  echo "$(date): Starting socat forwarding services"
  create_socat_services
  
  echo "$(date): Starting Wireguard"
  wg-quick up wg0
  
  trap stop_tunnel TERM INT QUIT
  
  wg
  
  while :; do
    if [ $(timeout 5 wg | wc -l) == 0 ]; then
      exit 1
    fi
    sleep 10
  done
}

main
