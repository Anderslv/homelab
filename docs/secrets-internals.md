---
title: Secrets Internals
---

# Secrets Internals

This page is for maintainers: how values travel from the compose files to a running container, which file does what, and why it is built this way. For daily use, read [Secrets](secrets.md).

---

## Data Flow

```text
docker-compose.yml + services/*.yml        every ${VAR}, with its kind and stack
              │
              │  scripts/secrets/map.sh
              ▼
        .env.example                        names, kinds, descriptions; never a value
              │
              │  scripts/secrets/setup.sh: choose stacks → check → fill
              │                ▲
              │                └── offered for import: an old .env, a copied secrets.yaml
              ▼
   KeePassXC  homelab/<env>/vars             one JSON object, one read, one write
              homelab/<env>/age-key          age private key (attachment keys.txt)
              │
              │  one read, piped into jq and sops (no plaintext file)
              ▼
   ~/.config/homelab-secrets/secrets.yaml    sops + age          (default)
   <repo>/.env                               plain, mode 600     (--output env)
   ~/.config/homelab-secrets/compose.yml     the stacks you set up
              │
              │  ./secrets.sh compose …   decrypts in memory, exports .env.example names only
              ▼
        docker compose -f compose.yml --project-directory <repo> …
```

`setup.sh` is the only writer of KeePassXC. `secrets.sh` never opens KeePassXC, so a machine with `secrets.yaml` and the age key runs the stack without the vault.

---

## What Each File Does

| File | Job |
| --- | --- |
| `secrets.sh` | Daily use: decrypts `secrets.yaml` once, exports the allowed values, `exec`s compose or your command. |
| `scripts/secrets/setup.sh` | The eight steps, top to bottom: preflight, map, choose, unlock, check, fill, store, write. Holds no logic of its own. |
| `scripts/secrets/map.sh` | Refreshes `.env.example`, or `--check`s that it is current. |
| `scripts/secrets/lib/ui.sh` | `✓ ✗ − !` lines, `ask_yn`, `menu`, hidden input typed twice. Everything on stderr. |
| `scripts/secrets/lib/config.sh` | Every path and its override; the `config` file (read as data, never sourced). |
| `scripts/secrets/lib/map.sh` | Compose → stacks, profiles, variables, kinds, dependencies, volumes, through `docker compose config --no-interpolate`. |
| `scripts/secrets/lib/example.sh` | Renders `.env.example` and parses it back, so the format lives in one place. |
| `scripts/secrets/lib/choose.sh` | The profile and stack menus, dependencies, the infra warning, first-setup variables. |
| `scripts/secrets/lib/values.sh` | Automatic values, placeholders, validation, the timezone picks, the `.env` reader. |
| `scripts/secrets/lib/vault.sh` | KeePassXC: unlock, environment groups, the `vars` JSON read and verified write. |
| `scripts/secrets/lib/vault-keys.sh` | The age key and label entries, vault backups, the running-app warning. |
| `scripts/secrets/lib/fill.sh` | Check and Fill: `✓`/`✗` per variable, the `[a e g s]` menu, `.env` import. |
| `scripts/secrets/lib/fill-live.sh` | The live-data guardrail: no automatic secret for a stack that holds data. |
| `scripts/secrets/lib/rotate.sh` | `--rotate VAR`, `--rotate age-key`, `--finish-age-key-rotation`. |
| `scripts/secrets/lib/output.sh` | `.sops.yaml`, `secrets.yaml`, `.env`; the change listing and its confirmation. |
| `scripts/secrets/lib/age-key.sh` | Installs the age key, keeping any other identities in `keys.txt`; swaps a rotated key. |
| `scripts/secrets/lib/output-compose.sh` | Writes the local `compose.yml` with only set-up stacks active. |
| `scripts/secrets/lib/docker.sh` | `docker_mode` (rootless, rootful, colima, down), the rootful warning, live-data signs. |
| `dev/tests/secrets-setup.test.sh` | Runs every case; `--only NAME` runs some. |
| `dev/tests/secrets/harness.sh` | Scratch space, the sandbox, shims, `expect_*` checks. |
| `dev/tests/secrets/cases/*.sh` | The cases, one file per area (map, choose, vault, fill, output, rotate, run, docker, guards, …). |
| `dev/tests/secrets/fixture/` | A four-stack compose project the cases copy into each sandbox. |

Every lib file opens with a short comment saying what it does and why it exists, and stays near 150 lines.

---

## Adding A Variable

1. Use it in a compose file. For a required value, put the hint in the `:?` message; it becomes the first description line:

    ```yaml title="services/vert.yml"
    environment:
      - VERT_API_TOKEN=${VERT_API_TOKEN:?Create a token in the VERT settings}
    ```

2. Run the map and read the new entry:

    ```bash title="Refresh the map"
    $ scripts/secrets/map.sh
      ✓ .env.example updated (+1 new, −0 removed)

    $ git diff .env.example
    …
    +# ── vert · services/vert.yml · profiles: apps dev prod ──────────────────────
    +# Create a token in the VERT settings
    +# (required · secret · vert)
    +VERT_API_TOKEN=
    +
    ```

3. Improve the description line if needed and commit `.env.example` with the compose change. The next `scripts/secrets/setup.sh` run asks for the value.

The pre-commit hook and CI run `map.sh --check`, so a forgotten map fails before review. A name containing `PASS`, `SECRET`, `TOKEN`, `KEY` or `PIN` is a secret: typed hidden and twice, generated when required. `secrets.sh` exports only names listed in `.env.example`, so a variable missing from the map never reaches compose.

---

## How The Tests Sandbox Themselves

```bash title="Run the suite"
$ bash dev/tests/secrets-setup.test.sh
…
  ✓ nothing in the real HOME secrets folders changed during the run

898 passed, 0 failed
Test files kept in /tmp/secrets-setup-test.Fke3Sk
```

A full run takes about 4 minutes. `--only NAME` runs the cases whose name or case file contains `NAME`, for example `--only rotate`.

The rules every case follows:

- **A throwaway `HOME` exists only inside `env -i`.** Each script under test runs under `env -i` with `HOME`, `TMPDIR` and `PATH` pointing into its own case folder and `GIT_CONFIG_GLOBAL=/dev/null`. The test runner's shell and the scripts themselves never change `HOME`.
- **Inherited settings are dropped.** The harness unsets every `HOMELAB_*`, `KEEPASSXC_*` and `SOPS_AGE_KEY_FILE` from your shell before the first case.
- **Nothing is deleted recursively.** Scratch space comes from one `mktemp -d`, is kept after the run, and its path is printed at the end. There is no cleanup trap.
- **The real `HOME` is checked.** A last case fails if anything under `~/.config/homelab-secrets`, `~/.config/sops` or `~/.local/state/homelab-secrets` changed during the run.
- **Throwaway everything else:** a git repo copied from the fixture, a vault made with `keepassxc-cli db-create -t 100`, `docker` shims for rootful, rootless, Colima, down and existing volumes, and answers piped on stdin.
- **No secret in the output.** Failing checks print labels only; the last output of each case stays in its folder for debugging.

The suite is written for Bash 3.2; CI runs it under Bash 5. Nix users can run `nix run .#secrets-setup-tests`.

---

## Design Decisions

- **One JSON entry per environment.** `keepassxc-cli` cannot read many entries in one unlock (a batched `open` session ignores piped commands), and the spike measured about 1 second per unlock on a vault made by the KeePassXC app. One `vars` entry makes a full run about 3 unlocks, under 10 seconds; the test suite holds a 60-variable check to that limit.
- **Values only through pipes.** Bash 3.2 writes here-strings and heredocs to temporary files, so secrets travel through `printf … |` and shell variables only; a guard case fails on `<<<` or a heredoc in the secrets code.
- **Bash 3.2, BSD and GNU tools.** Stock macOS runs the scripts without Homebrew Bash or Nix; no `declare -A`, `mapfile`, `sed -i` or `readlink -f`.
- **One vault, a group per environment.** Machines in one environment share values; different environments never share one by accident.
- **An age key per environment.** A dev machine cannot decrypt prod's `secrets.yaml`.
- **A local `compose.yml`.** Compose checks every `${VAR:?}` in every included file, so a partial setup needs an include list without the stacks you skipped. It lives outside the repo, so the git tree never differs per machine.
- **The live-data guardrail.** A new password for a stack with data locks its apps out of their database; setup refuses to generate one when a volume, a `.env` value or an unreachable Docker says data may exist.
- **An allowlist for `secrets.sh`.** Anyone can encrypt a file to the public age key, so only names in `.env.example` are exported, never shell, loader, Docker, Compose or sops variables.
- **`.env.example` as the map, not TOML.** People know the format, it doubles as the `.env` template, and Bash 3.2 parses it without a library. Its metadata sits on a comment line above each `VAR=`, so a copied file holds empty values instead of comments.
- **Consent for changes, not additions.** A first write and new names need no prompt, so CI finishes in one run; a changed or removed name always needs a person.

### Where This Differs From nix-config

A sibling nix-config setup, which this design follows, has the same shape: KeePassXC as the source, derived sops files outside the repo, the same `[a e g s]` menu and test harness. The homelab differs where it has to:

| nix-config | homelab | Why |
| --- | --- | --- |
| one entry per secret | one JSON `vars` entry per environment | ~1 second per unlock; a stack has dozens of variables |
| one `nix-config` group | `homelab/<env>` groups, an age key each | prod and dev hosts must not share values |
| `nix/secret-names.txt`, written by hand | `.env.example`, generated from compose | no variable can be missed |
| sops-nix decrypts at activation | `secrets.sh` exports at run time | the homelab runs on Fedora and macOS without Nix |
| `secrets.yaml` and `host.yaml` | one `secrets.yaml`, or a `.env` opt-out | no Nix evaluation needs host values |
| scratch removed after the tests | scratch kept, path printed | no recursive delete anywhere |
| — | live-data guardrail, local `compose.yml`, rootful Docker warning | databases and partial stacks exist only here |
