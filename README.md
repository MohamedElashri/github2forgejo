# github2forgejo

One–way bulk GitHub to Forgejo mirror script. Non-destructive (no deletes). Imports all repositories owned by a user into a Forgejo user or organization as mirrors (default) or one-time clones. On reruns, mirrors are force-synced and the default branch `HEAD` is verified to match GitHub.

## Features

* One–way mirror: GitHub -> Forgejo only
* Bulk, all-or-nothing import of owned repos
* Always authenticated to GitHub
* No tokens in clone URLs (auth passed via API payload)
* Optional `.env` loading
* Optional cron install for continuous mirroring
* Automatic mirror sync on rerun and HEAD verification

## Usage

Quick start with `.env`:

```bash
# 1) Copy and edit the template
cp template.env .env

# 2) Run a mirror import (safe to rerun; will sync and verify)
./github2forejo.sh --env ./.env --strategy mirror

# 3) Optional: install a daily cron at 02:00 using your .env
./github2forejo.sh --env ./.env --strategy mirror --install-cron
```

Run with CLI args (no `.env`):

```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export FORGEJO_TOKEN=forgejo_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

./github2forejo.sh \
  --github-user <Github_Username> \
  --forgejo-url https://forgejo.example.com \
  --forgejo-user <Forgejo_Username> \
  --strategy mirror
```

Clone once (no continuous updates):

```bash
./github2forejo.sh --env ./.env --strategy clone
```

Custom cron schedule:

```bash
./github2forejo.sh --env ./.env --strategy mirror \
  --install-cron \
  --cron-schedule "30 3 * * *"
```

## Options (CLI)

| Option            | Required | Type   | Default     | Description                                                                                            |
| ----------------- | -------- | ------ | ----------- | ------------------------------------------------------------------------------------------------------ |
| `--github-user`   | Yes\*    | string | none        | GitHub username owning the repos. Required unless provided via `GITHUB_USER` in environment or `.env`. |
| `--forgejo-url`   | Yes      | string | none        | Forgejo base URL. Must start with `https://`. Can be set by `FORGEJO_URL`.                             |
| `--forgejo-user`  | Yes      | string | none        | Forgejo user or org to receive the repos. Can be set by `FORGEJO_USER`.                                |
| `--strategy`      | No       | enum   | `mirror`    | `mirror` for continuous updates, `clone` for one-time import. Can be set by `STRATEGY`.                |
| `--env`           | No       | path   | none        | Load key=value pairs from a `.env` file. CLI overrides `.env`.                                         |
| `--install-cron`  | No       | flag   | `false`     | Append a crontab entry for periodic mirroring. Can be set by `INSTALL_CRON=true`.                      |
| `--cron-schedule` | No       | string | `0 2 * * *` | Cron expression for `--install-cron`. Can be set by `CRON_SCHEDULE`.                                   |
| `-h`, `--help`    | No       | flag   | n/a         | Show help and exit.                                                                                    |

## Environment variables

| Variable        | Required | Purpose                                                             |
| --------------- | -------- | ------------------------------------------------------------------- |
| `GITHUB_TOKEN`  | Yes      | GitHub PAT with read access to your repos. Always used.             |
| `FORGEJO_TOKEN` | Yes      | Forgejo token that can create/import repos for the target user/org. |
| `GITHUB_USER`   | Yes\*    | GitHub username owning the repos. May be provided via CLI instead.  |
| `FORGEJO_URL`   | Yes      | Forgejo base URL (must be https). May be provided via CLI.          |
| `FORGEJO_USER`  | Yes      | Forgejo user/org target. May be provided via CLI.                   |
| `STRATEGY`      | No       | `mirror` or `clone`. Defaults to `mirror`.                          |
| `CRON_SCHEDULE` | No       | Cron expression, defaults to `0 2 * * *`.                           |
| `INSTALL_CRON`  | No       | `true` or `false`. Defaults to `false`.                             |

## `.env` example

```env
# Required tokens
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
FORGEJO_TOKEN=forgejo_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Required targets (can be provided via CLI instead)
GITHUB_USER=<Github_Username>
FORGEJO_URL=https://forgejo.example.com
FORGEJO_USER=<Forgejo_Username>

# Optional
STRATEGY=mirror
CRON_SCHEDULE=0 2 * * *
INSTALL_CRON=false
```

## Behavior and scope

* One way only: GitHub to Forgejo.
* Bulk, all or nothing: imports all repos owned by `GITHUB_USER`; no per-repo selection.
* On reruns in mirror mode: each existing mirror is force-synced, then the default branch HEAD is verified to match GitHub. If mismatched, the script reports it.
* Private repos are mirrored when the GitHub token permits access.
* Tokens are not embedded in clone URLs; authentication is passed via the Forgejo migrate API payload.

