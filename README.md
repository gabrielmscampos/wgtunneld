# wgtunneld: WireGuard Tunnel with Port Forwarding

## Overview

`wgtunneld` is a two-part system (`wgtunneld-server` and `wgtunneld-client`) that uses **WireGuard** to create a secure tunnel between a **cloud VM with a static IP** and a **client running behind NAT or firewalls**.  
It forwards incoming traffic from the public server into private services running on the client.  

Port forwarding is handled with **socat**, and rules are defined in simple YAML files.

This project is based on [docker-wireguard-tunnel](bgithub.com/DigitallyRefined/docker-wireguard-tunnel). While it works wonderfully, I find it a bit confusing to declare the forwarding rules as environment variables, mix the client and server code and generate more than wireguard config for multiple peers.

---

## Architecture

- **Server (`wgtunneld-server`)**
  - Runs on a cloud VM with a **static public IP**.
  - Terminates the WireGuard tunnel.
  - Accepts incoming connections and forwards them to the client.

- **Client (`wgtunneld-client`)**
  - Runs in the local/private environment.
  - Connects to the server via WireGuard.
  - Forwards tunneled traffic into local services (e.g., Traefik).
  - TLS termination is done **in the reverse proxy**, not in the tunnel itself.

---

## wgtunneld-server

- Generates WireGuard server + peer keys at startup.
- Creates:
  - `/etc/wireguard/wg0.conf` → server config.
  - `/etc/wireguard/peer.conf` → client config (to be copied to the client).
- Reads forwarding rules from `/etc/forwarding.yaml`.
- Starts `socat` listeners to forward traffic to the client.

### Example forwarding.yaml

```yaml
forward:
  - sourceIp: 0.0.0.0
    sourcePort: 80/tcp
    destinationPort: 81/tcp
  - sourceIp: 0.0.0.0
    sourcePort: 443/tcp
    destinationPort: 444/tcp
```

### Example docker-compose.yaml

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

### Deployment Notes

- Must run on a **cloud VM with a static IP**.  
- Copy the generated `peer.conf` from `./config` to the **client**.  
- Forwarding is defined in `forwarding.yaml`.  

---

## wgtunneld-client

- Requires `/etc/wireguard/wg0.conf` (copied from server-generated `peer.conf`).
- Reads service rules from `/etc/services.yaml`.
- Starts `socat` listeners to forward traffic from the tunnel to local services.
- Keeps WireGuard connection alive.

### Example services.yaml

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
- Tunnel `:444/tcp` → service `traefik:444/tcp`
- Tunnel `:81/tcp` → service `traefik:81/tcp`

The `traefik` hostname must be reachable inside the wgtunneld-client container, therefore it is recommended to this container to same docker network as your reverse proxy.

### Example docker-compose.yaml

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

### Deployment Notes

- Place the server-generated `peer.conf` inside `./config` as `/etc/wireguard/wg0.conf`.  
- The client must run in the same Docker network (`frontend` in this example) as the **reverse proxy** (e.g., Traefik).  
- TLS termination (HTTPS certificates, routing, etc.) is handled **inside your reverse proxy**, not in the WireGuard tunnel.  

---

## Setup Workflow

1. **Start the server container** on a cloud VM.  
   - It generates WireGuard configs.  
   - Copy `peerconf` from `./config` to the client.  

2. **Configure forwarding rules** on the server (`forwarding.yaml`).  

3. **Start the client container** in the private environment.  
   - Mount `peer.conf` as `/etc/wireguard/wg0.conf`.  
   - Define service mapping in `services.yaml`.  

4. **Connect services**  
   - Public requests hit the server’s static IP.  
   - Server forwards traffic through the WireGuard tunnel.  
   - Client forwards to the local reverse proxy.  
   - Reverse proxy (e.g., Traefik) terminates TLS and routes requests.  

---

## Limitations

- **Source IP not preserved** due to `socat`. Reverse proxies will see the source as the WireGuard client container IP.  
- Requires a **cloud VM with a static public IP** for reliable access.  
- No built-in TLS support in the tunnel → TLS must be handled by the reverse proxy on the client side.  

