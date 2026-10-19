---
title: Secrets
---

# Secrets From Your Password Manager

Use this guide to keep the stack's passwords and API tokens in a password manager instead of a plaintext `.env` file. Two scripts do the work:

- **`setup_homelab.sh`** finds every secret the enabled compose services use and asks you for the missing ones.
- **`secrets.sh`** loads those secrets from the password manager and runs `docker compose` with them.

You never edit a secret reference by hand. Each secret is stored under its variable name, for example `IMMICH_DB_PASSWORD`.

---

## Try It Now

```bash title="Store secrets in KeePassXC and start the stack"
# 1. Choose a backend and database, then add the missing secrets
$ ./setup_homelab.sh ~/homelab.kdbx --backend keepassxc
No database at /Users/you/homelab.kdbx. Create it? [y/N] y
New password for /Users/you/homelab.kdbx:
Repeat password:
[INFO] Created /Users/you/homelab.kdbx
[INFO] Using keepassxc (/Users/you/homelab.kdbx)
[WARN] rustfs is missing: RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY
Add secrets for rustfs now? [y/N] y
  RUSTFS_ACCESS_KEY (required, Enter = generate a random value):
  RUSTFS_SECRET_KEY (required, Enter = generate a random value):
...
[INFO] Done. Rerun ./setup_homelab.sh at any time to add secrets you skipped.

# 2. Start the stack with the secrets loaded
$ ./secrets.sh compose --profile dev up --wait
Password for /Users/you/homelab.kdbx:
[+] Running ...
```

Enter generates a random value (64 hex characters, safe inside URLs) for **required** secrets. For **optional** secrets, Enter stores an empty value, so you are not asked again. Change a value later in your password manager.

The script saves your backend and database in `.secrets.conf` (gitignored, readable only by you), so later runs need no flags. The file holds the database location, never a password.

---

## Choose A Backend

| Backend | `--backend` | "Database" | Where a secret lives |
| --- | --- | --- | --- |
| **KeePassXC** | `keepassxc` | `.kdbx` file (default `~/homelab.kdbx`) | Root-group entry titled `<VAR>`, value in **Password** |

Without `--backend` and without a saved choice, the script shows a menu. Without a database argument and without a saved, working database, it asks for one and retries until the database opens. A wrong password or a missing vault sends you back to the prompt.

!!! warning "Use a dedicated KeePassXC database"
    The KeePassXC backend unlocks the database once and keeps a decrypted copy of **all** its entries in memory while the script runs. Point it at a database that holds only homelab secrets, such as `~/homelab.kdbx`, never your personal vault. The copy is never written to disk.

Required tools:

- **KeePassXC**: `keepassxc-cli` (bundled with the app; on macOS the script finds it in `/Applications/KeePassXC.app`) and `xmllint`
- Everything: `docker` and `jq`

The Nix dev shell provides `jq` and `xmllint`.

---

## Check Only Some Services

`--profile` takes any profile defined in the compose project, or `all` (the default). Add service names after it to check only those.

```bash title="Limit the check"
$ ./setup_homelab.sh --profile infra
$ ./setup_homelab.sh --profile apps immich-server paperless-web

$ ./setup_homelab.sh --profile utils
[ERROR] Unknown profile 'utils'. Available: all apps dev infra prod service tunnel

$ ./setup_homelab.sh --profile tunnel rustfs
[ERROR] Service 'rustfs' is not in profile 'tunnel'. Available: cftunnel prowlarr
```

Services without a `profiles:` key (such as `prowlarr`) are always enabled, so they appear in every profile.

---

## How Secrets Are Found

`lib/secrets-common.sh` runs `docker compose config --no-interpolate --format json`. That gives the merged project with every `${VAR}` reference intact, and it only includes stacks that `docker-compose.yml` includes. A commented-out include is never checked.

A variable counts as a **secret** when either is true:

- compose requires it: `${VAR:?message}`
- its name matches `SECRET_NAME_PATTERN` (`PASS|SECRET|TOKEN|KEY|PIN`)

The result is written to **`secrets.inventory`**, a committed list of one `SERVICE VARIABLE KIND` line per secret. It holds variable names only, never values. You never edit it by hand:

- `./update_secrets_inventory.sh` regenerates it and lists added and removed secrets.
- `./setup_homelab.sh` runs it first, and the pre-commit hook runs it when a compose file changes.
- CI runs `./update_secrets_inventory.sh --check` and fails when the file is out of date.

Add a new service with `${MY_APP_PASSWORD:?...}` and the next `./setup_homelab.sh` asks for it.

`secrets.sh` reads the inventory, so it does not need to parse the compose files. It loads **all** secrets, not only those of the services you start, because compose interpolates every included service. A missing secret is reported before compose's own error:

```bash title="A secret that is not stored yet"
$ ./secrets.sh compose --profile dev up -d
[WARN] Not in your keepassxc store: RUSTFS_SECRET_KEY (run ./setup_homelab.sh)
error while interpolating services.rustfs.environment.[]: required variable RUSTFS_SECRET_KEY is missing a value
```

### What `secrets.sh` Protects, And What It Does Not

- Secrets are never written to disk. They live in the environment of `docker compose`, which passes them to the containers.
- `secrets.sh run CMD` gives **every** secret to `CMD` and anything it starts. Only run commands you trust.
- Values in a container's environment are visible to anyone who can run `docker inspect` on the host. Compose secrets (below) avoid that.

---

## Add Another Backend

A backend is one file, `lib/backends/<name>.sh`, that sets two variables and defines four functions:

```bash title="lib/backends/example.sh"
BACKEND_DB_LABEL="Example vault"   # empty when there is no database to choose
BACKEND_DB_DEFAULT="homelab"

backend_open() { ...; }            # $1 = database; check tools, unlock, return 1 if unusable
backend_has()  { ...; }            # $1 = NAME; return 0 if the secret exists
backend_get()  { ...; }            # $1 = NAME; print the value
backend_set()  { ...; }            # $1 = NAME, $2 = value; store it
```

The new file appears in the `setup_homelab.sh` menu and in `--backend` automatically.

---

## Environment Variables Or Compose Secrets?

**Compose secrets** (`secrets:`) mount a value as a file at `/run/secrets/<name>` instead of setting an environment variable. A Compose secret can take its value from an environment variable, so it works with `secrets.sh` unchanged:

```yaml title="Compose secret fed by secrets.sh"
secrets:
  immich_db_password:
    environment: IMMICH_DB_PASSWORD

services:
  immich-postgres:
    secrets: [immich_db_password]
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/immich_db_password
```

The benefit is that the value no longer shows up in `docker inspect` or in the container's process environment. This repo still uses environment variables everywhere, for these reasons:

- **The image must read a file.** It only works when the image supports a `*_FILE` variable (for example, the official Postgres image's `POSTGRES_PASSWORD_FILE`) or a similar convention. Images without one need a custom entrypoint that reads the file and exports the variable.
- **Some secrets are built into larger strings.** `APP_KEY=base64:${SPEEDTEST_APP_KEY}` and connection URLs combine a secret with other text. A file mount cannot do that.
- **More wiring per secret.** Each secret needs a top-level `secrets:` entry, a service `secrets:` entry, and a `_FILE` variable, instead of one line.

Converting is a per-service change you can make gradually. Check that the image supports `*_FILE` first. The scripts here need no changes either way.

---

## Servers And Dockhand

- **Headless server**: install `keepassxc-cli` and copy the `.kdbx` file there. Run `./setup_homelab.sh` once, then `./secrets.sh compose --profile prod up -d`.
- **Dockhand**: Dockhand deploys from Git and reads variables from its own UI, not from your password manager. Copy the values there. See [Deployment](dockhand.md).

Related: [Services](services.md) lists which variables each service needs.
