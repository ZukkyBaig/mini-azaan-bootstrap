# Mini Adhan Bootstrap

One-command installer for deploying [Mini Adhan](https://github.com/ZukkyBaig/mini-adhan) onto a fresh Raspberry Pi OS Lite device.

## Usage

### Fully automatic (production provisioning)

Secrets are downloaded from R2 and decrypted with the provisioning password:

```bash
curl -fsSL https://raw.githubusercontent.com/ZukkyBaig/mini-adhan-bootstrap/main/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh --hostname=mini-adhan --version=stable --password=YOUR_PASSWORD
```

### Specific version

```bash
sudo bash /tmp/install.sh --hostname=mini-adhan-kitchen --version=v1.2.0 --password=YOUR_PASSWORD
```

### Dev device

```bash
sudo bash /tmp/install.sh --hostname=mini-adhan-dev --version=dev --password=YOUR_PASSWORD
```

### Interactive (prompts for everything)

```bash
curl -fsSL https://raw.githubusercontent.com/ZukkyBaig/mini-adhan-bootstrap/main/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh
```

All arguments are optional. Anything not provided is either downloaded from R2 (password prompted) or prompted interactively.

### Arguments

| Argument | Description |
|----------|-------------|
| `--hostname=NAME` | Set device hostname (skip prompt) |
| `--version=SPEC` | `stable`, `dev`, or a tag like `v1.2.0` (skip prompt) |
| `--password=PW` | Provisioning password to decrypt secrets bundle (skip prompt) |
| `--pem=PATH` | Path to GitHub App PEM file (skip R2 download) |
| `--ts-key=KEY` | Tailscale auth key (skip R2 download) |

### Offline install

If R2 is unreachable, provide keys manually:

```bash
scp gh-app.pem pi@<pi-ip>:/tmp/
sudo bash /tmp/install.sh --pem=/tmp/gh-app.pem --ts-key=tskey-auth-...
```

### Creating the encrypted secrets bundle

Bundle the PEM and Tailscale key into an encrypted archive for R2:

```bash
tar cf secrets.tar gh-app.pem tailscale-authkey.txt
openssl enc -aes-256-cbc -pbkdf2 -in secrets.tar -out secrets.enc -pass pass:YOUR_PASSWORD
# Upload secrets.enc to the R2 bucket
rm secrets.tar
```

## tmux protection

The installer runs inside a tmux session automatically. If your SSH connection drops:

```bash
tmux attach -t mini-adhan-install
```

## What it does

1. Installs OS packages (git, python3, alsa-utils, avahi-daemon, tmux, dnsmasq-base, etc.)
2. Sets device hostname (from `--hostname=` or prompted)
3. Downloads and decrypts secrets bundle from R2 (PEM + Tailscale key)
4. Installs Tailscale with hostname matching the device
5. Selects version (from `--version=` or prompted)
6. Generates a GitHub App installation token from the PEM
7. Clones the private app repo using the token
8. Stores credentials at `/etc/mini-adhan/` for future `adhan update` and `adhan rotate-key`
9. Creates Python venv and installs dependencies
10. Seeds config, installs systemd units, configures ALSA
11. Starts services and prints summary with version, URLs, and SSH access

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

The installer is idempotent — it reuses existing credentials, skips config seeding if the file exists, and does `git pull` if the repo is already cloned.
