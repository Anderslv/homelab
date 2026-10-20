---
title: Secrets
---

# Variables And Secrets

**No secret is ever committed to this repo, encrypted or not.**

The fork is public. Anything pushed is archived by others and stays readable forever. An encrypted file is only as safe as its cipher, and today's encryption may be broken tomorrow. So every value lives in **KeePassXC**, a vault that never has to be public, and the repo holds only variable names.

Every value counts as confidential, not just passwords: your domain, timezone and e-mail address say where you live and who you are.

Two scripts do the work:

- **`scripts/secrets/setup.sh`** finds every variable the compose files use, asks for the missing ones, stores them in KeePassXC and writes a local file the stack runs from.
- **`./secrets.sh`** runs `docker compose` (or any command) with those values.

Maintainers: see [Secrets Internals](secrets-internals.md) for how the pieces fit.

---

## Quick Start

Setup needs **KeePassXC**, **sops**, **age** and **jq**, next to Docker and git. On macOS, Homebrew installs them, and Colima (built on Lima) runs Docker. Every tool here is free software:

| Tool | Install on macOS | Licence | Telemetry |
| --- | --- | --- | --- |
| **KeePassXC** (`keepassxc-cli`) | `brew install --cask keepassxc` | GPL-2.0 / GPL-3.0 | none |
| **sops** | `brew install sops` | MPL-2.0 | none |
| **age** | `brew install age` | BSD-3-Clause | none |
| **jq** | `brew install jq` | MIT | none |
| **gitleaks** (pre-commit only) | fetched by the pre-commit hook | MIT | none |
| **Colima** | `brew install colima` | MIT | none |
| **Lima** (under Colima) | installed with Colima | Apache-2.0 | none |
| **Homebrew** | [brew.sh](https://brew.sh) | BSD-2-Clause | **on by default**: run `brew analytics off` |

On Fedora, `sudo dnf install keepassxc age jq` covers three of them; take `sops` from its [release page](https://github.com/getsops/sops/releases). On NixOS, `nix develop` (or `direnv allow`) gives you all of them.

Run setup from the repo root. It asks which part of the homelab you want, offers to create the vault, and fills what it can by itself:

```bash title="First setup: Immich plus infra, in a new vault"
$ scripts/secrets/setup.sh ~/homelab.kdbx
  ! Docker runs as root. A container escape or anyone in the docker group gets root on this machine.
    Rootless Docker: https://docs.docker.com/engine/security/rootless/
  ✓ .env.example is up to date
Which part of the homelab do you want to set up?
  [1] dev    everything, local HTTPS on localhost.me
  [2] prod   everything, real domain and Let's Encrypt
  [3] infra  Traefik, Sablier, AdGuard, RustFS, NetAlertX, whoami
  [4] apps   pick stacks: immich paperless media karakeep listmonk …
  [5] tunnel
  [6] service
  Choose [1 2 3 4 5 6]: 4
Which stacks?
  [1] tools
  …
  [8] immich
  …
  Numbers separated by spaces, or all: 8
  ! infra is not selected. Traefik routes every app; without it nothing is reachable by name.
  Set up infra too? [Y/n]
  No vault at ~/homelab.kdbx. Create a new one? [Y/n]
  Password for the new vault:
  Password for the new vault (again):
  ✓ Created ~/homelab.kdbx
  − Vault backed up to ~/.local/state/homelab-secrets/backups/homelab.20261020-041404-1575131.kdbx
Which environment does this machine use?
  [n] new environment
  Choose [n]: n
  Name of the new environment [dev]:
  − Created the KeePassXC group homelab/dev
  ✗ TZ missing
  ✗ DOMAIN missing
  ✗ ACME_EMAIL missing (optional)
  − PGID uses default 1000
  …
  ✗ RUSTFS_ACCESS_KEY missing
  ✗ RUSTFS_SECRET_KEY missing
  …
  ✗ IMMICH_DB_PASSWORD missing
  …

10 variables missing. How do you want to set them?
  [a] automatically where possible, asking for the rest
  [e] from a .env file, asking for the rest
  [g] guided, choosing for each variable
  [s] skip all for now
  Choose [a e g s]: a

  TZ (default · setting): Container timezone used across compose stacks.
  [e] from a .env file  [m] enter now  [s] skip  [S] skip all remaining
  Choose [e m s S]: m
  Timezone:
  [1] Europe/Berlin
  [2] America/Vancouver
  [3] Asia/Kathmandu
  [4] Asia/Taipei
  [o] other
  Choose [1 2 3 4 o]: 1
  ✓ TZ set

  DOMAIN (default · setting): Local routing defaults. …
  [e] from a .env file  [m] enter now  [s] skip  [S] skip all remaining
  Choose [e m s S]: m
  DOMAIN [localhost.me]:
  Use localhost.me for DOMAIN? [Y/n]
  ✓ DOMAIN set
  ✓ RUSTFS_ACCESS_KEY set automatically
  ✓ RUSTFS_SECRET_KEY set automatically
  ✓ IMMICH_DB_PASSWORD set automatically
  ✓ 5 values stored and verified
  Label for the age key [primary]:
  ✓ Installed the age key in ~/.config/sops/age/keys.txt
  ✓ Wrote secrets.yaml and verified it decrypts
  ✓ Wrote ~/.config/homelab-secrets/compose.yml
  − Skipped optional: ACME_EMAIL CF_DNS_API_TOKEN AI_API_KEY EXTERNAL_IMMICH_URL IMMICH_API_KEY
  ✓ Setup finished.
```

The whole run takes under 5 seconds. Generated values are never printed.

Then start the stack through `secrets.sh`. It takes the same arguments as `docker compose`:

```bash title="Check what will start"
$ ./secrets.sh compose --profile dev config --services
immich-postgres
redis
immich-microservices
traefik-dev
sablier
immich-server
immich-power-tools
netalertx
rustfs
whoami
adguard
immich-machine-learning
```

Run `./setup-dev.sh` once first: it creates the mkcert certificate the `dev` profile serves `https://*.localhost.me` with (see the [README](https://github.com/jakob1379/homelab#start-the-main-stack)). Then `./secrets.sh compose --profile dev up --wait` starts exactly these services. That is the daily command; you rerun `setup.sh` only to add a stack, a value or a machine.

### Running Commands With Your Values

`secrets.sh` decrypts `secrets.yaml` in memory, exports each value and replaces itself with your command. A variable you already set in your shell wins:

```bash title="The shell wins over stored values"
$ ./secrets.sh run sh -c 'echo "$TZ $DOMAIN"'
Europe/Berlin localhost.me

$ TZ=UTC ./secrets.sh run sh -c 'echo "$TZ $DOMAIN"'
  − kept from your environment: TZ
UTC localhost.me
```

Before the first setup there is nothing to run from:

```bash title="secrets.sh before setup"
$ ./secrets.sh compose ps
  ✗ missing ~/.config/homelab-secrets/secrets.yaml; run scripts/secrets/setup.sh first
```

!!! note "`secrets.sh run` hands every value to the command"
    The command and everything it starts see all your values. Only run commands you trust.

To see a generated value, for example to log in to DumbAssets, open the entry `homelab/<env>/vars` in the KeePassXC app: its Password field holds every value as JSON. Or print one value with `./secrets.sh run sh -c 'echo "$DUMBASSETS_PIN"'`, which shows it on your terminal and in its scrollback.

---

## What Lives Where

| Place | Holds | Mode |
| --- | --- | --- |
| KeePassXC, group `homelab/<env>` | `vars`: every value as one JSON object in the Password field; `age-key`: the age private key (attachment `keys.txt`); `age-key-label` | your vault |
| `~/.config/homelab-secrets/` | `config` (vault path, environment, output), `.sops.yaml`, `secrets.yaml`, `secrets.prev.yaml`, `compose.yml` | folder 700, files 600 |
| `~/.config/sops/age/keys.txt` | the age private key | 600 |
| `~/.local/state/homelab-secrets/backups/` | a vault copy before each run that writes to it, newest 5 kept | folder 700, files 600 |
| repo `.env` (opt-out only) | plain values, written from KeePassXC | 600, gitignored, blocked from commits |
| repo `.env.example` | every variable's name, kind and description. **No values.** | tracked |

**KeePassXC is the source of truth.** Everything under `~/.config` is derived from it and can be written again at any time.

```bash title="The vault after the quick start"
$ keepassxc-cli ls -R ~/homelab.kdbx homelab
Enter password to unlock ~/homelab.kdbx:
dev/
  vars
  age-key-label
  age-key
```

```bash title="The derived files"
$ ls -la ~/.config/homelab-secrets
total 28
drwx------ 2 you you 4096 Oct 20 06:08 .
drwxr-xr-x 5 you you 4096 Oct 20 06:08 ..
-rw------- 1 you you  252 Oct 20 06:08 .sops.yaml
-rw------- 1 you you 4248 Oct 20 06:08 compose.yml
-rw------- 1 you you  180 Oct 20 06:08 config
-rw------- 1 you you 1790 Oct 20 06:08 secrets.yaml
```

Keep the vault outside the repo. Every path has an override, which the tests use to stay away from your real files:

| Path | Override |
| --- | --- |
| `~/.config/homelab-secrets` | `HOMELAB_SECRETS_DIR` |
| `~/.config/sops/age/keys.txt` | `HOMELAB_SECRETS_AGE_KEY_FILE` |
| `~/.local/state/homelab-secrets/backups` | `HOMELAB_SECRETS_BACKUP_DIR` |
| the vault | `KEEPASSXC_DATABASE`, or the first argument |
| a key file next to the password | `KEEPASSXC_KEYFILE` |
| the environment | `HOMELAB_SECRETS_ENV`, or `--env-name NAME` |

!!! note "A vault needs a password"
    `KEEPASSXC_KEYFILE` works together with a password. A vault protected by a key file alone is not supported.

Setup adds the homelab age key to `~/.config/sops/age/keys.txt` and keeps any other identities in that file. If that file belongs to another setup that refuses foreign keys, set `HOMELAB_SECRETS_AGE_KEY_FILE` to a file of its own, for both `setup.sh` and `secrets.sh`.

### The Variable Map

`.env.example` lists every `${VAR}` that any compose file uses. A leading `core` section holds the variables used across stacks (`TZ`, `DOMAIN`, …); then come the stacks in `docker-compose.yml` order. **`scripts/secrets/map.sh` generates it**, and `setup.sh` refreshes it on every run. You edit only the description lines:

```bash title=".env.example"
# ── immich · services/immich.yml · profiles: apps dev prod ──────────────────
…
# Password generator in the dev shell: mkpasswd -l 32 -s 1
# (required · secret · 4 services)
IMMICH_DB_PASSWORD=
```

The line in brackets says three things:

- **Kind:** `required` (`${VAR:?}`), `default X` (`${VAR:-X}`), or `optional` (`${VAR}` with no default).
- **Sensitivity:** `secret` when the name contains `PASS`, `SECRET`, `TOKEN`, `KEY` or `PIN` (any case), otherwise `setting`. You type a secret twice, hidden; a setting is shown and confirmed.
- **Services** that use it, or a count such as `4 services` when there are more than three.

The `VAR=` lines stay empty, so `.env.example` also works as a template for the `.env` opt-out.

---

## Choosing What To Set Up

Setup asks for the values of the stacks you pick, nothing else.

| Choice | Sets up |
| --- | --- |
| `[1] dev` | every stack, local HTTPS on `localhost.me` |
| `[2] prod` | every stack, your domain and Let's Encrypt |
| `[3] infra` | Traefik, Sablier, AdGuard, RustFS, NetAlertX, whoami |
| `[4] apps` | the stacks you pick from a numbered list |
| `[5]`… | every other profile in the compose files |

A **stack** is one file that `docker-compose.yml` includes: `services/immich.yml` is the stack `immich`. When a stack needs services from another stack, setup adds that stack and prints a `+` line naming it.

`--profile NAME [STACK…]` makes the same choice without the menus: the quick start's choice is `--profile apps networking rustfs immich`. `networking` and `rustfs` are the infra stacks. Name them yourself in runs with `--auto`, `--env` or `--skip-missing`, because those answer "no" to the infra question.

### Which Values Setup Asks For

| Kind | Shown as | `[a]` | `--auto` | `[g]` guided |
| --- | --- | --- | --- | --- |
| `required` | `✗ missing` | generated when possible, otherwise asked | generated when possible, otherwise left missing | asked |
| **first-setup** | `✗ missing` | asked | left missing | asked |
| `default X` | `− uses default X` | left alone | left alone | left alone |
| `optional` | `✗ missing (optional)` | skipped, listed at the end | skipped, listed at the end | asked |

The **first-setup** variables are `TZ` and `DOMAIN`, plus `ACME_EMAIL` and `CF_DNS_API_TOKEN` with `prod`, plus `GLUETUN_HEALTHCHECK_DISABLED` with `dev` (which `[a]` and `--auto` set to `true`). They have defaults, but setup asks for them once so you choose on purpose.

**Automatic values** are made only for secrets:

| Variable | Automatic value |
| --- | --- |
| `SPEEDTEST_APP_KEY` | 32 random bytes, base64 |
| `DUMBASSETS_PIN` | 6 random digits |
| `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` | 20 / 40 letters and digits |
| `GLUETUN_HEALTHCHECK_DISABLED` | `true`, with the `dev` profile only |
| any other required secret | 64 hex characters |
| `OPENVPN_*`, API tokens, settings | none: you type them |

`OPENVPN_USER` and `OPENVPN_PASSWORD` are required and never generated, so the media stack stays commented out in your local `compose.yml` until both have a value. In development, type any placeholder for both with `[m]` (typed values are accepted; only imports skip placeholders). With `GLUETUN_HEALTHCHECK_DISABLED=true`, the media routes then start without a working VPN. Store real credentials and set it to `false` with `--rotate` before using the download automation.

### The Local Stack File

Compose checks every `${VAR:?}` in every included file, even for stacks that don't start. So setup writes its own copy of the include list, `~/.config/homelab-secrets/compose.yml`, in which the stacks you have not set up are commented out:

```yaml title="~/.config/homelab-secrets/compose.yml"
# ~/.config/homelab-secrets/compose.yml. Written by scripts/secrets/setup.sh; edit freely.
# Stacks you have not set up are commented out. Run setup.sh again to add one.
# Commented include lines you add by hand are kept; other edits are replaced on the next run.
name: homelab
include:
  # Core infrastructure
  - "/home/you/homelab/services/networking.yml"  # Traefik, Sablier, Whoami, AdGuard
  - "/home/you/homelab/services/rustfs.yml"  # RustFS S3-compatible storage
  …
  - "/home/you/homelab/services/immich.yml"  # Immich photo management
  # - "/home/you/homelab/services/paperless-ngx.yml"  # not set up: scripts/secrets/setup.sh --profile apps paperless-ngx
  …
```

- A stack line is **active** when you picked the stack in this run or it was already active, **and** every required variable of the stack has a value.
- A line you comment out by hand stays commented, even when you pick its stack again. Remove the `#` to bring it back.
- A stack added upstream shows up as a new commented line.
- When the file changes, an interactive run lists the stacks that change (`− immich (active)`) and asks `Write compose.yml? [Y/n]`. Runs with `--auto`, `--env` or `--skip-missing` apply the change without asking, because the file holds no values.
- `secrets.sh compose` uses this file unless you pass your own `-f` or set `COMPOSE_FILE`. Dockhand and CI keep using `docker-compose.yml`.

---

## Setting Up A New Machine

Pick the case that fits. For a new environment with no values yet, follow the [Quick Start](#quick-start) and choose `[n] new environment`.

### The Vault Already Holds The Values

Copy or sync the vault to the new machine, then run setup and pick the environment:

```bash title="A second machine in the dev environment"
$ scripts/secrets/setup.sh ~/homelab.kdbx
…
  KeePassXC password for ~/homelab.kdbx:
  ✓ Unlocked ~/homelab.kdbx
Which environment does this machine use?
  [1] dev
  [n] new environment
  Choose [1 n]: 1
  ✓ TZ in KeePassXC
  ✓ DOMAIN in KeePassXC
  …
  ✓ IMMICH_DB_PASSWORD in KeePassXC
  …
  ✓ Installed the age key in ~/.config/sops/age/keys.txt
  ✓ Wrote secrets.yaml and verified it decrypts
  ✓ Wrote ~/.config/homelab-secrets/compose.yml
  ✓ Setup finished.
```

**Environments** are groups in the vault: `homelab/dev`, `homelab/prod`. Machines in the same environment share values and the age key, so they can copy `secrets.yaml` between them. Each environment has its own age key, so a dev machine cannot decrypt prod's file.

Without prompts, name the environment:

```bash title="The same, without prompts"
$ scripts/secrets/setup.sh ~/homelab.kdbx --env-name dev --profile apps networking rustfs immich --skip-missing
…
  KeePassXC password for ~/homelab.kdbx:
  ✓ Unlocked ~/homelab.kdbx
  ✓ TZ in KeePassXC
  …
  ✓ Installed the age key in ~/.config/sops/age/keys.txt
  ✓ Wrote secrets.yaml and verified it decrypts
  ✓ Wrote ~/.config/homelab-secrets/compose.yml
  − Still missing: ACME_EMAIL CF_DNS_API_TOKEN AI_API_KEY EXTERNAL_IMMICH_URL IMMICH_API_KEY. Run setup.sh again to set them.
  ✓ Setup finished.
```

`--auto`, `--env FILE` and `--skip-missing` never ask: stdin carries only the vault password. The vault path, environment and output are remembered in `~/.config/homelab-secrets/config`, so later runs need no `DATABASE` argument.

### You Copied `secrets.yaml` From Another Machine

Copy `~/.config/homelab-secrets/secrets.yaml` and `~/.config/sops/age/keys.txt` from a machine that has them. Setup decrypts the file and offers each value for KeePassXC, so the vault becomes the source of truth again:

```bash title="Values found in a copied secrets.yaml"
$ scripts/secrets/setup.sh ~/homelab.kdbx
…
  − TZ found in secrets.yaml
  Store it in KeePassXC? [Y/n]
  − DOMAIN found in secrets.yaml
  Store it in KeePassXC? [Y/n]
  …
  − IMMICH_DB_PASSWORD found in secrets.yaml
  Store it in KeePassXC? [Y/n]
  …
  ✓ 5 values stored and verified
  Label for the age key [primary]:
  ✓ secrets.yaml is up to date
  ✓ Wrote ~/.config/homelab-secrets/compose.yml
```

### You Have An Old `.env`

Import it with `[e]`, or with `--env FILE`. The file is read as text and never run. Secrets are masked, known placeholders (`1234`, `rustadmin`, `local-openvpn-*`, `ci-*`, `CHANGEME*`) are ignored, and only missing variables are taken. With `--auto`, setup imports first and then generates the rest:

```bash title="Import an old .env, generate the rest"
$ scripts/secrets/setup.sh ~/homelab.kdbx --env-name dev --profile apps networking rustfs immich --env ~/old.env --auto
…
  ✓ Unlocked ~/homelab.kdbx
  …
    TZ=Europe/Berlin
    DOMAIN=localhost.me
  − RUSTFS_ACCESS_KEY: ignoring a placeholder value
    IMMICH_DB_PASSWORD=••••
  ✓ Took 3 values from ~/old.env
  ✓ RUSTFS_ACCESS_KEY set automatically
  ✓ RUSTFS_SECRET_KEY set automatically
  ✓ 5 values stored and verified
  ✓ Installed the age key in ~/.config/sops/age/keys.txt
  ✓ Wrote secrets.yaml and verified it decrypts
  ✓ Wrote ~/.config/homelab-secrets/compose.yml
  − Skipped optional: ACME_EMAIL CF_DNS_API_TOKEN AI_API_KEY EXTERNAL_IMMICH_URL IMMICH_API_KEY
  ✓ Setup finished.
```

Interactively, setup lists what it found and asks `Store these 3 values? [y/N]` first. Delete the old file once its values are in KeePassXC.

---

## The `.env` Opt-Out

`--output env` writes a plain `.env` in the repo root instead of `secrets.yaml`. Compose reads it by itself, so the daily command stays `./secrets.sh compose …`. Setup remembers the choice:

```bash title="Switch to a plain .env"
$ scripts/secrets/setup.sh --output env --profile apps networking rustfs immich --skip-missing
…
  ✓ Unlocked ~/homelab.kdbx
  …
  ✓ Wrote .env
  ! .env holds your values in plain text. It is gitignored and blocked from commits.
  ✓ compose.yml is up to date
  …
  ✓ Setup finished.

$ ls -l .env
-rw------- 1 you you 312 Oct 20 06:09 .env

$ cut -d= -f1 .env
# Written by scripts/secrets/setup.sh from KeePassXC. Plain text: never commit it.
TZ
DOMAIN
RUSTFS_ACCESS_KEY
RUSTFS_SECRET_KEY
IMMICH_DB_PASSWORD
```

- Values still come from KeePassXC; `.env` is just another derived file.
- Only Compose reads `.env`. `./secrets.sh run CMD` exports nothing with this output, so `CMD` sees no values.
- The previous file is kept as `.env.prev`, which is ignored and blocked too.
- `--output sops` switches back. A `.env` left next to a sops setup gets a warning from `secrets.sh`, because Compose reads it as well.

---

## Rotation

Rotation is simpler than usual because nothing is in git: there is no old ciphertext to re-encrypt and no history to clean.

### One Value

`--rotate VAR` replaces one value. It also sets an optional or default variable that has no value yet:

```bash title="Rotate a database password"
$ scripts/secrets/setup.sh --profile apps immich --rotate IMMICH_DB_PASSWORD
…
  ✓ Unlocked ~/homelab.kdbx

Rotating IMMICH_DB_PASSWORD (required · secret): Password generator in the dev shell: mkpasswd -l 32 -s 1
  − KeePassXC keeps the old value in the history of the vars entry.
  [a] automatically  [e] from a .env file  [m] enter now  [c] cancel
  Choose [a e m c]: a
  ✓ IMMICH_DB_PASSWORD set automatically
  − Vault backed up to ~/.local/state/homelab-secrets/backups/homelab.20261020-041010-1553632.kdbx
  ✓ 5 values stored and verified
  secrets.yaml will change:
  − IMMICH_DB_PASSWORD (changed), as --rotate asked
  ✓ Wrote secrets.yaml and verified it decrypts
  ✓ compose.yml is up to date
  − Still missing: ACME_EMAIL CF_DNS_API_TOKEN AI_API_KEY EXTERNAL_IMMICH_URL IMMICH_API_KEY. Run setup.sh again to set them.
  ✓ Setup finished.
```

!!! warning "Change a database password in the database first"
    Postgres reads `IMMICH_DB_PASSWORD` only when it creates the database. Change the password inside the running database, then store the same value with `--rotate VAR` and `[m]`. `[a]` is refused for a stack that already holds data (see [Guardrails](#guardrails)).

```bash title="Set an optional value later"
$ scripts/secrets/setup.sh --profile infra --rotate ACME_EMAIL
…
Rotating ACME_EMAIL (optional · setting): Production HTTPS override example: you@example.com
  [e] from a .env file  [m] enter now  [c] cancel
  Choose [e m c]: m
  ACME_EMAIL []: you@example.com
  Use you@example.com for ACME_EMAIL? [Y/n]
  ✓ ACME_EMAIL set
  − Vault backed up to ~/.local/state/homelab-secrets/backups/homelab.20261020-041250-1571662.kdbx
  ✓ 6 values stored and verified
  secrets.yaml will change:
  − ACME_EMAIL (added), as --rotate asked
  ✓ Wrote secrets.yaml and verified it decrypts
  ✓ compose.yml is up to date
  − Still missing: CF_DNS_API_TOKEN. Run setup.sh again to set them.
  ✓ Setup finished.
```

A rotation changes only the variable it names. Run each other machine's setup afterwards to pick up the new value.

### The Age Key

Rotate it when a machine is lost, the key file leaked, or once a year. It takes three steps.

1. On one machine, `--rotate age-key`. The old key moves to `age-key-previous` in the vault, and `secrets.yaml` is re-encrypted to the new key:

    ```bash title="Step 1: rotate"
    $ scripts/secrets/setup.sh --profile infra --rotate age-key
    …
      ✓ Unlocked ~/homelab.kdbx
      − Vault backed up to ~/.local/state/homelab-secrets/backups/homelab.20261020-041020-1554713.kdbx
      ✓ Kept the old age key in homelab/dev/age-key-previous
      ✓ Stored a new age key in homelab/dev/age-key
      − Run setup.sh on every other machine to install it, then setup.sh --finish-age-key-rotation.
      − The age key was rotated; kept the old file at ~/.config/sops/age/keys.txt.rotated-20261020-041021
      ✓ Replaced the old age key in ~/.config/sops/age/keys.txt
      ✓ Re-encrypted secrets.yaml to the new age key
      ✓ secrets.yaml is up to date
      ✓ compose.yml is up to date
      − Still missing: ACME_EMAIL CF_DNS_API_TOKEN. Run setup.sh again to set them.
      ✓ Setup finished.
    ```

2. On every other machine in the environment, run setup. It recognises the old key, sets it aside the same way and installs the new one. A local key that matches neither is refused.
3. When every machine is done, finish the rotation:

    ```bash title="Step 3: finish"
    $ scripts/secrets/setup.sh --finish-age-key-rotation
    …
      ✓ Unlocked ~/homelab.kdbx

    Every machine should have run setup.sh since the rotation, so it holds the new age key.
      Move homelab/dev/age-key-previous to KeePassXC's recycle bin? [Y/n]
      − Vault backed up to ~/.local/state/homelab-secrets/backups/homelab.20261020-041040-1557335.kdbx
      ✓ Moved homelab/dev/age-key-previous to the recycle bin
      − Old local key kept at ~/.config/sops/age/keys.txt.rotated-20261020-041021; delete it once you're sure.
    ```

A new age-key rotation is refused until the previous one is finished.

### Which To Rotate

| Event | Rotate |
| --- | --- |
| Machine lost or compromised | the age key, then every secret that machine had |
| One token or password leaked | that value |
| `.kdbx` leaked, strong master password | the master password and key file; long-lived secrets |
| `.kdbx` leaked, weak or shared master password | everything |
| Routine | the age key yearly; tokens as the provider asks |

Change the KeePassXC master password in the KeePassXC app. Old copies of the vault, including the backups in `~/.local/state/homelab-secrets/backups/`, still open with the old password; delete the ones you control.

---

## Guardrails

**A stored value is never replaced** except by `--rotate`. Values found elsewhere are offered for import, never taken silently.

**Live data stops automatic passwords.** A new password for a stack that already holds data would lock its apps out of their own database. Setup looks for the stack's Docker volumes, and for a repo `.env` that sets one of its secrets:

```bash title="Immich already has a database"
$ scripts/secrets/setup.sh ~/homelab.kdbx --env-name dev --profile apps networking rustfs immich --auto
…
  ✓ RUSTFS_ACCESS_KEY set automatically
  ✓ RUSTFS_SECRET_KEY set automatically
  ! immich already has data (volume homelab_immich_postgres_data).
    A new IMMICH_DB_PASSWORD would lock Immich out of its database.
    Import it from .env [e] or type the current value [m].
  ✓ 2 values stored and verified
  …
  − Still missing: TZ DOMAIN IMMICH_DB_PASSWORD. Run setup.sh again to set them.
  − Skipped optional: ACME_EMAIL CF_DNS_API_TOKEN AI_API_KEY EXTERNAL_IMMICH_URL IMMICH_API_KEY
  ✗ Resolve these, then rerun: IMMICH_DB_PASSWORD
```

The run exits 1, so nothing half-works silently. When Docker is not reachable, setup cannot rule out live data and refuses every automatic secret of the chosen stacks:

```bash title="Docker is not running"
$ scripts/secrets/setup.sh ~/homelab.kdbx --env-name dev --profile apps networking rustfs immich --auto
  − Docker not running; skipping the rootless check
…
  ✗ Docker is not running, so I can't check whether your stacks already hold data.
    A new password for a stack that has data would lock its apps out of their databases.
    Start Docker and rerun, or import from .env [e] / type the current value [m].
…
  ✗ Resolve these, then rerun: RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY IMMICH_DB_PASSWORD
```

**Derived files change only with your consent.** The first write of `secrets.yaml` or `.env` asks nothing. Later, setup lists the **names** that would change, never the values, and asks:

```bash title="A value changed in KeePassXC since this machine's last run"
$ scripts/secrets/setup.sh --profile apps networking rustfs immich
…
  secrets.yaml will change:
  − IMMICH_DB_PASSWORD (changed)
  Write secrets.yaml? [Y/n]
  ✓ Wrote secrets.yaml and verified it decrypts
```

A run with `--auto`, `--env` or `--skip-missing` adds new names without asking, but refuses to change or remove one:

```bash title="The same change, without prompts"
$ scripts/secrets/setup.sh --profile apps networking rustfs immich --skip-missing
…
  secrets.yaml will change:
  − IMMICH_DB_PASSWORD (changed)
  ✗ A non-interactive run never changes existing values.
  ✗ Left secrets.yaml unchanged.
```

The previous file is kept as `secrets.prev.yaml` (or `.env.prev`), and every written file is read back and compared.

**More checks:**

- **One wrong password stops a run without a terminal**; at a terminal you get 3 tries:

    ```bash title="Wrong vault password"
    $ scripts/secrets/setup.sh --profile apps networking rustfs immich --skip-missing
    …
      KeePassXC password for ~/homelab.kdbx:
      ✗ Wrong password or key file.
      ✗ Could not unlock ~/homelab.kdbx; giving up.
    ```

- **A git-tracked `.env` is never read or written**: `✗ .env is tracked by git; refusing to read secrets from it.`
- **`HOMELAB_SECRETS_DIR` and the age key's folder must be outside any git work tree**; setup refuses to write `secrets.yaml`, `.sops.yaml` or the age key there. The `.env` opt-out is the one file written into the repo, and only while git ignores it.
- **A local age key that differs from the vault's** is never overwritten: `holds a different key than KeePassXC; not touching it.`
- **The vault is backed up** before the first write of each run; runs that change nothing make no backup.
- **The KeePassXC app**: setup warns when it is running, because saving the vault there can overwrite what setup wrote. Lock the vault in the app first.
- **Unreadable is not missing.** Any KeePassXC error other than "not found" stops the run before it changes anything.
- **Docker runs as root?** Setup warns and continues. Under Colima it adds `(inside the Colima VM, so it is isolated from macOS)`.

**Git refuses secret files.** `.gitignore` covers `.env`, `.env.*` (except `.env.example`), `*.kdbx`, `*.agekey`, `*.sops.*`, `.sops.yaml`, `keys.txt`, `age-key.txt` and `/secrets/`. The pre-commit hooks refuse those files even when force-added, refuse any value in `.env.example`, run `map.sh --check`, `detect-private-key` and **gitleaks**:

```bash title="A new compose variable makes the map stale"
$ scripts/secrets/map.sh --check
  ✗ .env.example is stale. Run scripts/secrets/map.sh and commit the result.
  − new: VERT_API_TOKEN

$ scripts/secrets/map.sh
  ✓ .env.example updated (+1 new, −0 removed)
```

---

## Threat Model

**What this protects:**

- **Git and the public fork.** No value, encrypted or not, is ever committed.
- **The repo folder.** With the default output, nothing secret is in it; you can share, zip or back it up.
- **Other passwords in a shared vault.** `keepassxc-cli` decrypts the vault in its own memory to unlock it, but setup reads only the `homelab/<env>` entries. Nothing else from the vault reaches its variables, its output or the files it writes.
- **Command lines.** Values reach `keepassxc-cli`, `sops` and `jq` only through pipes, never as arguments, so `ps` never shows them. On the sops path no plaintext value touches a file: the new `secrets.yaml` is written as ciphertext beside the old one, then moved into place. The `.env` opt-out writes `.env.tmp` (mode 600) beside `.env` and moves it into place; a trap removes it if the run stops.
- **A planted `secrets.yaml`.** Anyone can encrypt a file to your public age key. `secrets.sh` therefore exports only names listed in `.env.example`, and never names that steer the shell, the loader, Docker, Compose or sops (`PATH`, `LD_*`, `DYLD_*`, `DOCKER_*`, `COMPOSE_*`, `SOPS_*`, …):

    ```bash title="A secrets.yaml with names it should not have"
    $ ./secrets.sh run sh -c 'echo "TZ=$TZ LD_PRELOAD=${LD_PRELOAD:-unset}"'
      ! skipped LD_PRELOAD: not a variable in .env.example
      ! skipped PROMPT_COMMAND: not a variable in .env.example
      ! skipped SOMETHING_ELSE: not a variable in .env.example
    TZ=UTC LD_PRELOAD=unset
    ```

    The allowlist limits the names, not the values: a planted file still sets `TZ` to what the attacker chose. Keep `~/.config/homelab-secrets` writable only by you (it is mode 700).

**What this does not protect:**

- **Docker's copy of the environment.** Docker stores each container's environment in `/var/lib/docker`, readable by root; on macOS that is inside the Colima VM. `docker inspect` shows it to anyone who can reach the Docker socket.
- **Rootful Docker.** Anyone in the `docker` group is root-equivalent on the host. Prefer [rootless Docker](https://docs.docker.com/engine/security/rootless/) on Linux.
- **The age key on disk.** `~/.config/sops/age/keys.txt` sits at mode 600 next to the file it decrypts. Local encryption keeps values out of casual reads and backups, not away from your own user account. Protect the machine with disk encryption and a screen lock.
- **The `.env` opt-out.** It is plain text at mode 600.
- **A leaked vault.** A `.kdbx` can be attacked offline forever. Use a long random master password, and add a key file next to it.

---

Related: [Secrets Internals](secrets-internals.md) · [Services](services.md) lists the variables each service needs · [Deployment](dockhand.md) for Dockhand.
