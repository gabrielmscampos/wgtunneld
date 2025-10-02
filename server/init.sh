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
Address = 10.8.0.1/32
ListenPort = $wireguard_port
MTU = $wireguard_mtu
SaveConfig = false

[Peer]
PublicKey = $peer_public
AllowedIPs = 10.8.0.2/32
EOF

  # Peer configuration
  cat > /etc/wireguard/peer.conf <<EOF
[Interface]
PrivateKey = $peer_private
Address = 10.8.0.2/32
MTU = $wireguard_mtu
SaveConfig = false

[Peer]
PublicKey = $server_public
Endpoint = $wireguard_ip:$wireguard_port
AllowedIPs = 10.8.0.1/32
PersistentKeepalive = 25
EOF
}

configure_iptables() {
  # Read each forwarding rule from YAML
  mapfile -t forward < <(yq e -o=tsv '.forward[] | [.sourceIp, .sourcePort, .destinationPort]' /etc/forwarding.yaml)

  # Enable forwarding
  iptables -I FORWARD 1 -i eth0 -o wg0 -j ACCEPT
  iptables -I FORWARD 2 -i wg0 -o eth0 -j ACCEPT
  
  for f in "${forward[@]}"; do
    IFS=$'\t' read -r sourceIp sourcePort destinationPort <<< "$f"
  
    src_port=${sourcePort%/*}
    src_proto=${sourcePort#*/}
    dst_port=${destinationPort%/*}
    dst_proto=${destinationPort#*/}

    if [ "$src_proto" = "tcp" ] || [ "$src_proto" = "udp" ]; then
      iptables -t nat -A PREROUTING -i eth0 -p $src_proto --dport $src_port -j DNAT --to-destination 10.8.0.2:$dst_port
      iptables -t nat -A POSTROUTING -o wg0 -p $src_proto -d 10.8.0.2 --dport $dst_port -j SNAT --to-source 10.8.0.1
    else
      echo "Error: unsupported protocol '$src_proto'. Only 'tcp' or 'udp' are allowed." >&2
      exit 1
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
 
  echo "$(date): Starting Wireguard"
  wg-quick up wg0
  
  echo "$(date): Configuring iptables"
  configure_iptables

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
