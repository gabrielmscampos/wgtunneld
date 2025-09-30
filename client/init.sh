#!/usr/bin/env bash

create_socat_services() {
  # Kill any old socat processes
  pkill socat 2>/dev/null || true

  # Read each service rule from YAML
  mapfile -t services < <(yq e -o=tsv '.services[] | [.sourcePort, .destinationIp, .destinationPort]' /etc/services.yaml)
  
  for f in "${services[@]}"; do
    IFS=$'\t' read -r sourcePort destinationIp destinationPort <<< "$f"
  
    src_port=${sourcePort%/*}
    src_proto=${sourcePort#*/}
    dst_port=${destinationPort%/*}
    dst_proto=${destinationPort#*/}

    if [ "$src_proto" = "tcp" ]; then
      socat TCP-LISTEN:$src_port,bind=0.0.0.0,fork TCP:$destinationIp:$dst_port &
    elif [ "$src_proto" = "udp" ]; then
      socat UDP-LISTEN:$src_port,bind=0.0.0.0,fork UDP:$destinationIp:$dst_port &
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
    echo "$(date): Wireguard configuration not found. Exiting."
    exit 1
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
