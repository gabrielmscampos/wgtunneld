# wgtunneld: WireGuard Tunnel with Port Forwarding

## Overview

`wgtunneld` is a two-part system (`wgtunneld-server` and `wgtunneld-client`) that uses **WireGuard** to create a secure tunnel between a **cloud VM with a static public IP** and a **client running behind NAT or firewalls**.  

It enables port forwarding from the server’s public IP into private services on the client.  
Forwarding rules are defined in simple YAML files and implemented with **socat**.

This project is based on [docker-wireguard-tunnel](https://github.com/DigitallyRefined/docker-wireguard-tunnel), but read rules from yaml files, separates client/server code, and generate only one peer key.

---

## Architecture

- **Server (`wgtunneld-server`)**
  - Runs on a cloud VM with a static IP.
  - Forwards incoming traffic to the client.

- **Client (`wgtunneld-client`)**
  - Runs in the local/private environment.
  - Connects to the server via WireGuard.
  - Forwards tunneled traffic to local services (e.g., Traefik).


---

## Server (`wgtunneld-server`)

- Generates WireGuard server and peer keys at startup, if none is present in `/etc/wireguard`.
- Creates:
  - `/etc/wireguard/wg0.conf` → server config
  - `/etc/wireguard/peer.conf` → client config (to copy to the client)
- Reads forwarding rules from `/etc/forwarding.yaml`.
- Configure `iptables` to redirect traffic to the client.

### Example `forwarding.yaml`

```yaml
forward:
  - sourceIp: 0.0.0.0
    sourcePort: 80/tcp
    destinationPort: 81/tcp
  - sourceIp: 0.0.0.0
    sourcePort: 443/tcp
    destinationPort: 444/tcp
```

### Example `docker-compose.yaml`

```yaml
services:
  wgtunneld-server:
    image: ghcr.io/gabrielmscampos/wgtunneld-server:latest
    container_name: wgtunneld-server
    environment:
      - WIREGUARD_IP=REDACTED
      - WIREGUARD_PORT=51820
      - WIREGUARD_MTU=1280
    cap_add:
      - NET_ADMIN
    volumes:
      - ./config:/etc/wireguard
      - ./forwarding.yaml:/etc/forwarding.yaml
    restart: unless-stopped
    ports:
      - "51820:51820/udp"
      - "443:443/tcp"
      - "80:80/tcp"
```

---

## Client (`wgtunneld-client`)

- Requires `/etc/wireguard/wg0.conf` (the server-generated `peer.conf`).
- Reads service mappings from `/etc/services.yaml`.
- Uses `socat` to forward tunneled traffic to local services.

### Example `services.yaml`

```yaml
services:
  - sourcePort: 444/tcp
    destinationIp: traefik
    destinationPort: 444/tcp
  - sourcePort: 81/tcp
    destinationIp: traefik
    destinationPort: 81/tcp
```

This forwards:
- Tunnel `:444/tcp` → `traefik:444/tcp`  
- Tunnel `:81/tcp` → `traefik:81/tcp`  

> The `traefik` hostname must resolve inside the container, so the client should join the same Docker network as your reverse proxy.

### Example `docker-compose.yaml`

```yaml
services:
  wgtunneld-client:
    image: ghcr.io/gabrielmscampos/wgtunneld-client
    container_name: wgtunneld-client
    cap_add:
      - NET_ADMIN
    volumes:
      - ./config:/etc/wireguard
      - ./services.yaml:/etc/services.yaml
    restart: unless-stopped
    networks:
      - frontend

networks:
  frontend:
    external: true
```

---

## Limitations

- **Source IP is not preserved** → reverse proxies will see requests as coming from the WireGuard client container.  
- **No built-in TLS** → must be handled by the reverse proxy.  
- Adding a new forwarding/service requires a full restart of the container, this might no be a big deal for HTTP/HTTPS but gaming via UDP will be affected.

---

## Why not use `iptables` in the client?

The client implementation still uses `socat` instead of `iptables` for the following reasons:

- Unlike the server, the client needs to DNAT to different IPs within the network. If the user specifies a container hostname instead of an IP, we could resolve it using `getent`. However, `getent` only works if the container hostname is registered in the network. Consequently, if the client container is started while the backend services are down, the `iptables` rules will not be set up.
- If the IP of a container in the network changes (for example, due to a restart), the client container will not be aware of it and would need to automatically reconfigure the `iptables` rules.

A simple implementation of the `iptables` logic, that do not solve the problems stated earlier, would be:

```bash
configure_iptables() {
  # Read each service rule from YAML
  mapfile -t services < <(yq e -o=tsv '.services[] | [.sourcePort, .destinationIp, .destinationPort]' /etc/services.yaml)

  ipv4_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  declare -A seen_ifaces
  
  for f in "${services[@]}"; do
    IFS=$'\t' read -r sourcePort destinationIp destinationPort <<< "$f"
  
    src_port=${sourcePort%/*}
    src_proto=${sourcePort#*/}
    dst_port=${destinationPort%/*}
    dst_proto=${destinationPort#*/}

    if [[ $destinationIp =~ $ipv4_regex ]]; then
	 # Validate that each octet is 0–255
	 valid=true
	 IFS='.' read -r o1 o2 o3 o4 <<< "$destinationIp"
	 for octet in $o1 $o2 $o3 $o4; do
	   if ((octet < 0 || octet > 255)); then
	     valid=false
		 break
		fi
	 done

	 if [[ $valid == true ]]; then
	   echo "Using IP: $destinationIp"
	 else
	   echo "Invalid IP range, resolving hostname: $destinationIp"
	   destinationIp=$(getent hosts "$destinationIp" | awk '{print $1; exit}')
	   echo "Resolved to: $destinationIp"
	 fi
	else
	 echo "Not an IPv4, resolving hostname: $destinationIp"
	 destinationIp=$(getent hosts "$destinationIp" | awk '{print $1; exit}')
	 echo "Resolved to: $destinationIp"
	fi 

    iface=$(ip route get "$destinationIp" | awk '/dev/ { print $3 }')
    [ -n "$iface" ] && seen_ifaces["$iface"]=1

    # Using MASQUERADE instead of SNAT due to its dynamic nature
    if [ "$src_proto" = "tcp" ] || [ "$src_proto" = "udp" ]; then
      iptables -t nat -A PREROUTING -i wg0 -p $src_proto --dport $dst_port -j DNAT --to-destination $destinationIp:$dst_port
      iptables -t nat -A POSTROUTING -o $iface -p $src_proto -d $destinationIp --dport $dst_port -j MASQUERADE
    else
      echo "Error: unsupported protocol '$src_proto'. Only 'tcp' or 'udp' are allowed." >&2
      exit 1
    fi

  done

  # Add FORWARD rules for each unique iface
  for iface in "${!seen_ifaces[@]}"; do
    echo "Allowing forwarding between wg0 and $iface"
    iptables -I FORWARD -i wg0 -o "$iface" -j ACCEPT
    iptables -I FORWARD -i "$iface" -o wg0 -j ACCEPT
  done
}
```

