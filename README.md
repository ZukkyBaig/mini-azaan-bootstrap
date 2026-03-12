# Mini Adhan Bootstrap

One-command installer for deploying [Mini Adhan](https://github.com/ZukkyBaig/mini-adhan) onto a fresh Raspberry Pi OS Lite device.

## Usage

SSH into the Pi, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/ZukkyBaig/mini-adhan-bootstrap/main/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh
```

The PEM key is downloaded automatically from Cloudflare R2. For offline installs or if R2 is down:

```bash
scp gh-app.pem pi@<pi-ip>:/tmp/
curl -fsSL https://raw.githubusercontent.com/ZukkyBaig/mini-adhan-bootstrap/main/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh --pem=/tmp/gh-app.pem
```

The installer runs inside a tmux session automatically. If your SSH connection drops, reattach with:

```bash
tmux attach -t mini-adhan-install
```

## What it does

1. Installs OS packages (git, python3, alsa-utils, avahi-daemon, tmux, dnsmasq-base, etc.)
2. Installs and configures Tailscale for remote access
3. Prompts for a device hostname (default: `mini-adhan`)
4. Prompts for version selection:
   - **Latest stable release** (default) — clones main, checks out the latest git tag
   - **Specific version** — e.g. `v1.2.0`
   - **Development branch** — tracks `dev` branch head
5. Downloads PEM key from R2 and generates a GitHub App installation token
6. Clones the private app repo to `/opt/mini-adhan/app` using the token
7. Stores credentials at `/etc/mini-adhan/` for future `adhan update` and `adhan rotate-key`
8. Creates a Python venv and installs dependencies
9. Seeds `/etc/mini-adhan/config.yml` from the repo (only on first install)
10. Runs `deploy/system-update.sh` to install systemd units, ALSA config, and helper scripts
11. Sets USB audio PCM to 100% (hardware baseline for software volume control)
12. Starts the scheduler and web services
13. Prints a summary with Web UI URL, SSH access, and installed version

## Authentication

Uses a GitHub App installation token instead of SSH deploy keys. The PEM key is stored in Cloudflare R2 and downloaded automatically during install. R2 credentials in the script are read-only, scoped to a single bucket containing only the PEM file.

After install, credentials are stored at `/etc/mini-adhan/gh-app.{pem,conf}` so `adhan update` can generate fresh tokens without re-downloading.

To rotate the PEM key after a GitHub App key reset: `adhan rotate-key`

## Key paths on the Pi

| Path | Purpose |
|------|---------|
| `/opt/mini-adhan/app` | Cloned app repo |
| `/etc/mini-adhan/config.yml` | Persisted config (not overwritten on reinstall) |
| `/etc/mini-adhan/gh-app.pem` | GitHub App PEM key |
| `/etc/mini-adhan/gh-app.conf` | R2 + GitHub App IDs for token generation |
| `/usr/local/bin/adhan` | CLI entry point (symlink to `manage.sh`) |
| `/var/log/mini-adhan/install.log` | Installer log |

## Re-running

The installer is idempotent for most steps — it reuses an existing PEM if found at `/etc/mini-adhan/gh-app.pem`, skips config seeding if the file exists, and does `git pull` if the repo is already cloned.
