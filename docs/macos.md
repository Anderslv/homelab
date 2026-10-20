# Running On macOS With Colima

Use this page to run the stack on a Mac with **Colima** instead of a Linux host.

**Colima** runs the Docker daemon inside a small Linux VM (built on **Lima**). The `docker` and `docker compose` commands on your Mac talk to that VM. Most of the stack runs unchanged, but every "host" path, port, and network in the compose files now means the VM, not your Mac. This page covers where that matters.

**Colima** is MIT-licensed and **Lima** is Apache-2.0; neither sends telemetry. **Homebrew** (BSD-2-Clause) sends analytics by default, so the first step turns them off.

---

## Try It Now

```bash title="Install the tools"
# 0. Stop Homebrew's analytics
$ brew analytics off

# 1. Colima, the Docker CLI, and the Compose plugin
$ brew install colima docker docker-compose

# 2. Let the Docker CLI find the Compose plugin
$ mkdir -p ~/.docker
$ cat ~/.docker/config.json 2>/dev/null || echo '{}' > ~/.docker/config.json
# Add this key to ~/.docker/config.json:
#   "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]

# 3. mkcert, and the tools that keep your values in KeePassXC (see Secrets)
$ brew install mkcert sops age jq
$ brew install --cask keepassxc
```

The **Nix dev shell** (`nix develop`, or `direnv allow` with the included `.envrc`) provides `mkcert`, `sops`, `age`, `jq` and `keepassxc-cli` as well.

```bash title="Start the VM"
# 6 CPUs, 16 GiB RAM, 100 GiB disk, Rosetta for amd64-only images
$ colima start --vm-type vz --vz-rosetta --mount-type virtiofs --cpu 6 --memory 16 --disk 100

$ docker context show
colima
```

```bash title="Prepare and start the stack"
$ mkcert -install
$ ./setup-dev.sh

# Store the values in KeePassXC; see Secrets
$ scripts/secrets/setup.sh ~/homelab.kdbx --profile dev

# Home Assistant and NetAlertX are skipped; see "Skip The Host-Networked Services"
$ ./secrets.sh compose --profile dev up --wait --scale ha=0 --scale netalertx=0

$ curl https://whoami.localhost.me
Hostname: homelab-whoami-1
```

`localhost.me` resolves to `127.0.0.1`, and Colima forwards the published ports (`80`, `443`, `1053`, `3000`) from the VM to your Mac's localhost. Run `mkcert -install` on the Mac, not in the VM, so your browser trusts the certificate.

---

## Keep Your Values Out Of The Repo

`scripts/secrets/setup.sh` and `./secrets.sh` run on the **Bash 3.2** and BSD tools that ship with macOS; you need neither Homebrew Bash nor Nix. Setup stores every value in KeePassXC and writes an encrypted file under `~/.config/homelab-secrets`, outside the repo.

Setup also checks how Docker runs. Under Colima the daemon runs as root inside the VM, isolated from macOS:

```bash title="The Docker check under Colima"
$ scripts/secrets/setup.sh --profile infra --skip-missing
  ! Docker runs as root. A container escape or anyone in the docker group gets root on this machine.
    Rootless Docker: https://docs.docker.com/engine/security/rootless/
    (inside the Colima VM, so it is isolated from macOS)
  ✓ .env.example is up to date
…
```

Docker inside the VM keeps each container's environment in `/var/lib/docker`, readable by root in the VM. See [Secrets](secrets.md) for the full guide and threat model.

---

## What "Host" Means Under Colima

| Compose setting | Under Colima |
| --- | --- |
| `/var/run/docker.sock` mounts (Traefik, Sablier, Homepage, Dockhand) | The VM's Docker socket. Works unchanged. |
| `../config/...` bind mounts | Colima shares your home folder with the VM. Keep the repo under `~`. |
| Published ports (`80`, `443`, `1053`, `3000`) | Forwarded to `localhost` on your Mac. |
| `network_mode: host` (Home Assistant, NetAlertX) | The VM's network, which sits behind NAT. No LAN discovery. |
| `/etc/localtime`, `/etc/timezone`, `/run/dbus` mounts | The VM's files, not your Mac's. The `TZ` you stored with setup still sets the container timezone. |
| `/dev/net/tun` (Gluetun) | Provided by the VM kernel. Works unchanged. |

---

## Skip The Host-Networked Services

**Home Assistant** and **NetAlertX** use `network_mode: host` so they can see your LAN. Under Colima, the "host" is the VM, which sits behind NAT:

- **NetAlertX** scans `NETALERTX_SCAN_SUBNETS` (default `192.168.1.0/24`) with ARP. The VM is not on that network, so the scan finds nothing.
- **Home Assistant** gets no mDNS or SSDP discovery, and `/run/dbus` is the VM's D-Bus, so there is no Bluetooth.

Both are in the `dev` profile, so exclude them when you start the stack:

```bash title="Start the dev profile without them"
$ ./secrets.sh compose --profile dev up --wait --scale ha=0 --scale netalertx=0
```

If you run them anyway, Traefik reaches them through `host.docker.internal` (see `config/traefik/dyn/ha.yml`). Check that this name leads to the VM, where they listen:

```bash title="Check Traefik-to-Home Assistant reachability"
$ ./secrets.sh compose exec traefik-dev wget -O- http://host.docker.internal:8123/manifest.json
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
$ ./secrets.sh compose restart traefik-dev
```
