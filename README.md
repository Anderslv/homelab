# Homelab

[![CI](https://github.com/jakob1379/homelab/actions/workflows/test-docker-compose.yml/badge.svg)](https://github.com/jakob1379/homelab/actions/workflows/test-docker-compose.yml)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-Ready-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Traefik](https://img.shields.io/badge/Traefik-Proxy-24A1C1?logo=traefikproxy&logoColor=white)](https://traefik.io/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **Docker Compose homelab with two entrypoints.** `docker-compose.yml` runs the main stack. `docker-compose.pods.yml` boots **Dockhand** as the separate control plane.

This repo defaults to local HTTPS routing through **Traefik** at `https://<service>.localhost.me` using mkcert-generated local certificates. Production ACME certificates are handled by the alternate Cloudflare DNS-01 Traefik config.

---

## Try It Now (2 Minutes)

Start the bootstrap control plane first. This works without touching the main stack.

```bash title="Bootstrap Dockhand only"
# 1. Clone the repo
$ git clone https://github.com/jakob1379/homelab.git && cd homelab
Cloning into 'homelab'...
done.

# 2. Start the separate Dockhand stack
$ docker compose -f docker-compose.pods.yml up -d
[+] Running 1/1
 ✔ Container homelab-pods-dockhand-1  Started

# 3. Verify the direct bootstrap endpoint
$ curl -I http://localhost:3000
HTTP/1.1 200 OK
```

Open `http://localhost:3000`.

If you want the full routed stack, keep going.

On macOS, set up Colima first: see [docs/macos.md](docs/macos.md).

---

## Start The Main Stack

`setup-dev.sh` creates the local TLS certificate and checks the `env_file` references. It never creates, writes or reads `.env`; values are stored with `scripts/secrets/setup.sh`.

```bash title="Prepare local TLS files"
$ ./setup-dev.sh
[INFO] Setting up the homelab development environment...
[INFO] setup-dev.sh generates local TLS files and checks env_file references; it does not touch .env
[INFO] Generating local TLS certificate with mkcert for localhost.me
[INFO] Local Traefik TLS certificate configured: config/traefik/certs/localhost.me.pem
[INFO] Setup complete!
[INFO]
[INFO] Start the pods stack: docker compose -f docker-compose.pods.yml up -d
[INFO] Stop the main stack: ./secrets.sh compose down
[INFO] Next: store your values with scripts/secrets/setup.sh, then run ./secrets.sh compose --profile dev up --wait
```

Every value the stack needs (passwords, your domain, your timezone) lives in **KeePassXC**, never in the repo. `scripts/secrets/setup.sh` asks for what is missing, generates what it can, and writes an encrypted file outside the repo. `./secrets.sh` then runs `docker compose` with those values. See [Secrets](docs/secrets.md).

```bash title="Start the full stack"
# 2. Store the values in KeePassXC (creates the vault on first use)
$ scripts/secrets/setup.sh ~/homelab.kdbx --profile dev
…
30 variables missing. How do you want to set them?
  [a] automatically where possible, asking for the rest
  [e] from a .env file, asking for the rest
  [g] guided, choosing for each variable
  [s] skip all for now
  Choose [a e g s]: a
…
  ✓ RUSTFS_ACCESS_KEY set automatically
  ✓ RUSTFS_SECRET_KEY set automatically
…
  ✓ 17 values stored and verified
  Label for the age key [primary]:
  ✓ Installed the age key in ~/.config/sops/age/keys.txt
  ✓ Wrote secrets.yaml and verified it decrypts
  ✓ Wrote ~/.config/homelab-secrets/compose.yml
  − Still missing: OPENVPN_PASSWORD OPENVPN_USER. Run setup.sh again to set them.
…
  ✓ Setup finished.

# 3. Start the full local stack and wait for health checks
$ ./secrets.sh compose --profile dev up --wait
[+] Running ...
 ✔ Container homelab-traefik-1   Started
 ✔ Container homelab-sablier-1   Started
 ✔ Container homelab-rustfs-1    Started

# 4. Verify a routed endpoint
$ curl https://whoami.localhost.me
Hostname: homelab-whoami-1
IP: 172.20.0.2
```

!!! note
    Use service subdomains such as `https://whoami.localhost.me` or `https://traefik.localhost.me`. A request to plain `https://localhost.me` will not match a Traefik router.

---

## How The Repo Is Laid Out Now

### `docker-compose.yml`: main stack

This file includes the active stack definitions under `services/` plus `home-assistant/docker-compose.yml`.

```yaml title="docker-compose.yml"
include:
  - services/networking.yml
  - services/rustfs.yml
  - services/tools.yml
  - services/omni-tools.yml
  - services/speedtest-tracker.yml
  - services/vert.yml
  - services/anythingllm.yml
  - services/listmonk.yml
  - services/karakeep.yml
  - services/immich.yml
  - services/paperless-ngx.yml
  - services/dumbassets.yml
  - services/media.yml
  - services/hermes.yml
  - services/homepage.yml
  - home-assistant/docker-compose.yml
```

### `docker-compose.pods.yml`: bootstrap stack

This file includes only `services/pods.yml`.

```yaml title="docker-compose.pods.yml"
include:
  - services/pods.yml
```

### Active profiles

| Profile | Purpose |
|---|---|
| `dev` | Full main stack with local mkcert-backed Traefik HTTPS |
| `prod` | Full main stack with Cloudflare DNS-01 ACME Traefik HTTPS |
| `infra` | Always-on foundation services |
| `apps` | Most application services |
| `tunnel` | Optional `cftunnel` sidecar for Listmonk |
| `service` | Narrow profile currently used by Home Assistant |

Use exactly one full-stack profile at a time: `dev` or `prod`.

`home-assistant/docker-compose.yml` puts `ha` in `profiles: [apps, service, dev, prod]`.

---

## What Is Actually Routed

The routing model is split.

### File-provider routes in `config/traefik/dyn/*.yml`

These are the routes that currently use explicit **Traefik** file-provider config, usually because they also need **Sablier** middleware:

- **AnythingLLM**
- **BentoPDF**
- **CloudBeaver**
- **DumbAssets**
- **Homepage**
- **Home Assistant**
- **Immich Power Tools**
- **IT Tools**
- **Jellyfin**
- **Karakeep**
- **Listmonk**
- **NetAlertX**
- **Omni Tools**
- **Paperless-ngx**
- **RustFS**
- **Seerr**
- **Speedtest Tracker**
- **VERT**
- **whoami**

### Direct Docker-label routes

These are currently routed with service labels instead of `config/traefik/dyn/*.yml`:

- **AdGuard**
- **Dockhand**
- **Hermes**
- **Immich**
- **Prowlarr**
- **Bazarr**
- **Radarr**
- **Sonarr**
- **torrent** (`https://torrent.${DOMAIN}`)
- **Traefik dashboard**

### Sleep behavior right now

- **Sablier-managed**: `anythingllm`, `bentopdf`, `cbeaver`, `dumbassets`, `home`, `immich-power-tools`, `ittools`, `keep`, `omni-tools`, `paperless`, `seerr`, `speedtest-tracker`, `vert`, `whoami`
- **Always on / not wired to Sablier middleware**: `traefik`, `sablier`, `rustfs`, `adguard`, `netalertx`, `dockhand`, `immich`, `home-assistant`, `hermes`, `jellyfin`, `torrent`, `sonarr`, `radarr`, `prowlarr`, `bazarr`
- **Important exception**: `listmonk` still has `sablier.*` labels, but `config/traefik/dyn/listmonk.yml` does **not** attach a Sablier middleware. Treat it as not sleeping on request in the current repo.

---

## Current Service Groups

### Foundation

- **Traefik**
- **Sablier**
- **RustFS**
- **AdGuard Home**
- **NetAlertX**
- **whoami**

### Utilities and dashboards

- **Homepage**
- **AnythingLLM**
- **IT Tools**
- **CloudBeaver**
- **BentoPDF**
- **DumbAssets**
- **Omni Tools**
- **VERT**
- **Speedtest Tracker**
- **Hermes**

### App stacks

- **Karakeep** + `chrome` + `meilisearch`
- **Listmonk** + `listmonk-postgres` + optional `cftunnel`
- **Immich** + `immich-postgres` + `redis` + workers
- **Paperless-ngx** + PostgreSQL + Redis + Gotenberg + Tika
- **Media**: `jellyfin`, `seerr`, `immich-power-tools`, `torrent`, `sonarr`, `radarr`, `flaresolverr`, `byparr`, `prowlarr`, `bazarr`
- **Home Assistant**

---

## Current Caveats

### 1. Local HTTPS uses mkcert

Local development uses `config/traefik/traefik.yml` with HTTPS on `websecure`.
Run `setup-dev.sh` to create the mkcert-backed files for
`https://*.localhost.me`, then start the stack with:

```bash
./secrets.sh compose --profile dev up --wait
```

For production ACME certificates, run `scripts/secrets/setup.sh --profile prod`, which asks for `DOMAIN`, `ACME_EMAIL` and `CF_DNS_API_TOKEN`, then start the stack with `./secrets.sh compose --profile prod up -d`.

### 2. The media stack still depends on Gluetun

`services/media.yml` runs **Gluetun** as the shared network namespace for:

- `torrent`
- `sonarr`
- `radarr`
- `flaresolverr`
- `byparr`

`prowlarr` and `bazarr` route directly on `traefik_public`.

The active compose config requires `OPENVPN_USER` and `OPENVPN_PASSWORD` for Gluetun. Store real VPN credentials with `scripts/secrets/setup.sh` before running the VPN-backed media automation. Until both are stored, setup keeps the media stack commented out in your local `compose.yml`, so the rest of the stack still starts.

### 3. There are parked service definitions

These files exist but are **not** included from `docker-compose.yml`:

- `services/teable.yml`
- `services/teable-migrate.yml`

---

## Read The Right Doc

- [Docs index](docs/index.md)
- [Variables and secrets](docs/secrets.md)
- [Architecture](docs/architecture.md)
- [Service reference](docs/services.md)
- [Customization](docs/customization.md)
- [Deploy through Dockhand](docs/dockhand.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Queue-driven sleep status](docs/queue-driven-sleep.md)

---

## License

MIT. See [LICENSE](LICENSE).
