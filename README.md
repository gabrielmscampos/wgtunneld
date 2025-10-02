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
- Starts `socat` listeners to send traffic to the client.

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

