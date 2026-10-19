# Running On macOS With Colima

Use this page to run the stack on a Mac with **Colima** instead of a Linux host.

**Colima** runs the Docker daemon inside a small Linux VM (built on **Lima**). The `docker` and `docker compose` commands on your Mac talk to that VM. Most of the stack runs unchanged, but every "host" path, port, and network in the compose files now means the VM, not your Mac. This page covers where that matters.

Colima and Lima are MIT-licensed and send no telemetry.

---

## Try It Now

```bash title="Install the tools"
# 1. Colima, the Docker CLI, and the Compose plugin
$ brew install colima docker docker-compose

# 2. Let the Docker CLI find the Compose plugin
$ mkdir -p ~/.docker
$ cat ~/.docker/config.json 2>/dev/null || echo '{}' > ~/.docker/config.json
# Add this key to ~/.docker/config.json:
#   "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]

# 3. Bash 5 and mkcert (skip if you use the Nix dev shell; see below)
$ brew install bash mkcert
```

```bash title="Start the VM"
# 6 CPUs, 16 GiB RAM, 100 GiB disk, Rosetta for amd64-only images
$ colima start --vm-type vz --vz-rosetta --mount-type virtiofs --cpu 6 --memory 16 --disk 100

$ docker context show
colima
```

```bash title="Prepare and start the stack"
$ mkcert -install
$ ./setup-dev.sh

# Home Assistant and NetAlertX are skipped; see "Skip The Host-Networked Services"
$ docker compose --profile dev up --wait --scale ha=0 --scale netalertx=0

$ curl https://whoami.localhost.me
Hostname: homelab-whoami-1
```

`localhost.me` resolves to `127.0.0.1`, and Colima forwards the published ports (`80`, `443`, `1053`, `3000`) from the VM to your Mac's localhost. Run `mkcert -install` on the Mac, not in the VM, so your browser trusts the certificate.

---

## Use Bash 5, Not The macOS Default

macOS ships **Bash 3.2**. `setup-dev.sh`, `setup_homelab.sh`, and `update_secrets_inventory.sh` use Bash 4+ features (`${var,,}` and `mapfile`) and fail under 3.2:

```bash title="Failure under the macOS system bash"
$ ./setup-dev.sh
./setup-dev.sh: line 166: ${ci_value,,}: bad substitution
```

The scripts start with `#!/usr/bin/env bash`, so they use the first `bash` on your `PATH`. Either of these puts Bash 5 first:

- the repo's **Nix dev shell** (`nix develop`, or `direnv allow` with the included `.envrc`), which also provides `mkcert`
- `brew install bash`, since `/opt/homebrew/bin` comes before `/bin` on a default Homebrew `PATH`

```bash title="Check which bash the scripts get"
# Any 5.x version works
$ bash --version | head -1
GNU bash, version 5.2.37(1)-release (aarch64-apple-darwin24.0.0)
```

---

## What "Host" Means Under Colima

| Compose setting | Under Colima |
| --- | --- |
| `/var/run/docker.sock` mounts (Traefik, Sablier, Homepage, Dockhand) | The VM's Docker socket. Works unchanged. |
| `../config/...` bind mounts | Colima shares your home folder with the VM. Keep the repo under `~`. |
| Published ports (`80`, `443`, `1053`, `3000`) | Forwarded to `localhost` on your Mac. |
| `network_mode: host` (Home Assistant, NetAlertX) | The VM's network, which sits behind NAT. No LAN discovery. |
| `/etc/localtime`, `/etc/timezone`, `/run/dbus` mounts | The VM's files, not your Mac's. `TZ` in `.env` still sets the container timezone. |
| `/dev/net/tun` (Gluetun) | Provided by the VM kernel. Works unchanged. |

---

## Skip The Host-Networked Services

**Home Assistant** and **NetAlertX** use `network_mode: host` so they can see your LAN. Under Colima, the "host" is the VM, which sits behind NAT:

- **NetAlertX** scans `NETALERTX_SCAN_SUBNETS` (default `192.168.1.0/24`) with ARP. The VM is not on that network, so the scan finds nothing.
- **Home Assistant** gets no mDNS or SSDP discovery, and `/run/dbus` is the VM's D-Bus, so there is no Bluetooth.

Both are in the `dev` profile, so exclude them when you start the stack:

```bash title="Start the dev profile without them"
$ docker compose --profile dev up --wait --scale ha=0 --scale netalertx=0
```

If you run them anyway, Traefik reaches them through `host.docker.internal` (see `config/traefik/dyn/ha.yml`). Check that this name leads to the VM, where they listen:

```bash title="Check Traefik-to-Home Assistant reachability"
$ docker compose exec traefik-dev wget -O- http://host.docker.internal:8123/manifest.json
```

If that fails, the route returns a 502 or hangs. See [Home Assistant Hangs Or Shows "Retrying"](troubleshooting.md#home-assistant-hangs-or-shows-retrying).

---

## Apple Silicon And amd64-Only Images

On an Apple Silicon Mac the VM is `arm64`, so Docker pulls `linux/arm64` images. Most images in this repo publish one. These are the ones to check, because they use `:latest` or are pinned by digest:

- `ghcr.io/immich-power-tools/immich-power-tools:latest`
- `ghcr.io/thephaseless/byparr:latest`
- `gcr.io/zenika-hub/alpine-chrome@sha256:...` (`services/karakeep.yml`)
- `nousresearch/hermes-agent@sha256:...` (`services/hermes.yml`)
- `ghcr.io/vert-sh/vert@sha256:...` (`services/vert.yml`)

```bash title="List the platforms an image publishes"
$ docker buildx imagetools inspect traefik:3.6.9 | grep Platform
  Platform:    linux/amd64
  Platform:    linux/arm/v6
  Platform:    linux/arm64
  ...
```

A digest that points at a single-platform image prints no `Platform` lines; check its `MediaType` instead. If an image has no `linux/arm64` build, `--vz-rosetta` runs the amd64 build through **Rosetta**, which is much faster than QEMU emulation.

---

## Size The VM

Colima's default VM has 2 CPUs and 2 GiB of RAM. The `dev` profile's memory reservations add up to about 12 GiB, so start with 16 GiB.

```bash title="Resize an existing VM"
$ colima stop
$ colima start --cpu 6 --memory 16
```

You can change CPU and memory on any restart. You can grow the disk later but not shrink it.

---

## Troubleshooting

### `Cannot connect to the Docker daemon`

```bash title="Error when the VM is stopped or the context is wrong"
$ docker compose ps
Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
```

Start Colima and select its context:

```bash title="Start the VM and point the CLI at it"
$ colima start
$ docker context use colima
```

### `docker: 'compose' is not a docker command`

The Compose plugin is installed but the CLI cannot find it. Add `cliPluginsExtraDirs` to `~/.docker/config.json` as shown in [Try It Now](#try-it-now).

### `https://*.localhost.me` Does Not Answer

Check whether Traefik answers inside the VM. This tells you whether the problem is Traefik or the port forwarding to your Mac.

```bash title="Call Traefik from inside the VM"
$ colima ssh -- curl -sk -H 'Host: whoami.localhost.me' https://127.0.0.1
Hostname: homelab-whoami-1
```

- Works inside the VM but not on the Mac: run `colima restart` to reset the port forwarding.
- Fails inside the VM too: debug Traefik with the main [Troubleshooting](troubleshooting.md) page.

### Traefik Ignores Edits To `config/traefik/dyn/`

Traefik reloads routes when it sees file-change events. Edits made on the Mac do not always produce those events inside the VM. Restart Traefik to load the new routes:

```bash title="Reload the file-provider routes"
$ docker compose restart traefik-dev
```
