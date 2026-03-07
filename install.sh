#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="mini-azaan.service"
APP_ROOT="/opt/mini-azaan"
APP_DIR="${APP_ROOT}/app"
ETC_DIR="/etc/mini-azaan"
ETC_CONFIG="${ETC_DIR}/config.yml"
BIN_LINK="/usr/local/bin/mini-azaan"

REPO_URL="git@github.com:zukkybaig/mini-azaan.git"
GIT_REF="main"

LOG_DIR="/var/log/mini-azaan"
LOG_FILE="${LOG_DIR}/install.log"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

mkdir -p "${LOG_DIR}"
chmod 755 "${LOG_DIR}"
touch "${LOG_FILE}"
chmod 644 "${LOG_FILE}"

# Log everything (stdout+stderr) to file AND screen
exec > >(tee -a "${LOG_FILE}") 2>&1

echo
echo "========================================"
echo " Mini Azaan installer starting"
echo " $(date -Is)"
echo " Log: ${LOG_FILE}"
echo "========================================"
echo

# Ensure tmux exists early (so we can self-relaunch)
if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found. Installing tmux first..."
  apt-get update
  apt-get install -y tmux
fi

# Auto-run inside tmux unless already in tmux.
# IMPORTANT: When this script is invoked via 'sudo bash /path/to/install.sh ...',
# $0 is the script path but may not be executable. So we re-run via bash.
if [[ -z "${TMUX:-}" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    echo "Not running in tmux. Launching installer inside tmux session..."
    echo "If you disconnect, reattach with: tmux attach -t mini-azaan-install"

    # Preserve args safely for the tmux command string
    args=""
    for a in "$@"; do
      args+=" $(printf "%q" "$a")"
    done

    exec tmux new -s mini-azaan-install "bash $(printf "%q" "$0")${args}"
  else
    echo "No interactive terminal detected. Skipping tmux auto-launch."
    echo "Tip: run this script from an SSH session for tmux protection."
  fi
fi

echo "Running inside tmux session: ${TMUX:-none}"
echo

echo "Installing Mini Azaan..."
echo

RUN_USER="${SUDO_USER:-pi}"
RUN_HOME="$(getent passwd "${RUN_USER}" | cut -d: -f6)"
if [[ -z "${RUN_HOME}" ]]; then
  echo "Could not resolve home directory for user: ${RUN_USER}"
  exit 1
fi

SSH_DIR="${RUN_HOME}/.ssh"
KEY_PATH="${SSH_DIR}/id_ed25519"
PUB_PATH="${KEY_PATH}.pub"
CONFIGURED_HOSTNAME=""

install_packages() {
  echo "Installing OS packages..."
  apt-get update
  apt-get install -y \
    git \
    openssh-client \
    openssh-server \
    python3 \
    python3-venv \
    python3-pip \
    libsdl2-mixer-2.0-0 \
    avahi-daemon \
    tmux \
    alsa-utils
}

ensure_ssh_key() {
  echo "Ensuring SSH deploy key exists..."

  mkdir -p "${SSH_DIR}"
  chown "${RUN_USER}:${RUN_USER}" "${SSH_DIR}"
  chmod 700 "${SSH_DIR}"

  if [[ ! -f "${KEY_PATH}" ]]; then
    sudo -u "${RUN_USER}" ssh-keygen -t ed25519 -N "" -f "${KEY_PATH}" -C "mini-azaan-${RUN_USER}@$(hostname)"
  fi

  sudo -u "${RUN_USER}" bash -c "ssh-keyscan -H github.com >> '${SSH_DIR}/known_hosts' 2>/dev/null || true"
  chown "${RUN_USER}:${RUN_USER}" "${SSH_DIR}/known_hosts" 2>/dev/null || true
  chmod 644 "${SSH_DIR}/known_hosts" 2>/dev/null || true

  sudo -u "${RUN_USER}" bash -c "cat > '${SSH_DIR}/config' <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ${KEY_PATH}
  IdentitiesOnly yes
EOF"
  chown "${RUN_USER}:${RUN_USER}" "${SSH_DIR}/config"
  chmod 600 "${SSH_DIR}/config"
}

print_deploy_key() {
  echo
  echo "Add this public key to GitHub:"
  echo "Repo -> Settings -> Deploy keys -> Add deploy key"
  echo
  echo "----------------------------------------"
  cat "${PUB_PATH}"
  echo "----------------------------------------"
  echo
}

wait_for_enter() {
  echo "Press Enter once you've added the deploy key..."
  read -r _ < /dev/tty
}

prepare_dirs() {
  echo "Preparing directories..."
  mkdir -p "${APP_ROOT}"
  mkdir -p "${ETC_DIR}"
  chown -R "${RUN_USER}:${RUN_USER}" "${APP_ROOT}"
}

configure_hostname() {
  echo
  read -rp "Enter device hostname (default: mini-azaan): " NEW_HOSTNAME < /dev/tty
  NEW_HOSTNAME=${NEW_HOSTNAME:-mini-azaan}

  # Set hostname immediately on running system
  hostnamectl set-hostname "${NEW_HOSTNAME}"

  # Fix /etc/hosts
  if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
  else
    printf "127.0.1.1\t%s\n" "${NEW_HOSTNAME}" >> /etc/hosts
  fi

  # Disable cloud-init so it never stomps our config on reboot
  touch /etc/cloud/cloud-init.disabled

  CONFIGURED_HOSTNAME="${NEW_HOSTNAME}"

  echo
  echo "Device hostname configured as: ${CONFIGURED_HOSTNAME}"
  echo
}

ensure_repo() {
  echo "Ensuring app repo is present at ${APP_DIR}..."

  mkdir -p "${APP_ROOT}"
  chown -R "${RUN_USER}:${RUN_USER}" "${APP_ROOT}"

  if [[ -d "${APP_DIR}/.git" ]]; then
    echo "Repo already exists, updating..."
    sudo -u "${RUN_USER}" git -C "${APP_DIR}" fetch --all
    sudo -u "${RUN_USER}" git -C "${APP_DIR}" checkout "${GIT_REF}"
    sudo -u "${RUN_USER}" git -C "${APP_DIR}" pull
    return 0
  fi

  echo "Repo not found, cloning..."
  rm -rf "${APP_DIR}"
  sudo -u "${RUN_USER}" git clone "${REPO_URL}" "${APP_DIR}"
  sudo -u "${RUN_USER}" git -C "${APP_DIR}" checkout "${GIT_REF}" || true
}

ensure_repo_with_retry() {
  echo "Ensuring private repo access..."

  while true; do
    if ensure_repo; then
      echo "Repo ready."
      break
    fi

    echo "Repo clone/update failed. Ensure deploy key is added."
    print_deploy_key
    wait_for_enter
  done
}

setup_venv() {
  echo "Setting up virtual environment..."
  cd "${APP_DIR}"

  if [[ ! -d ".venv" ]]; then
    sudo -u "${RUN_USER}" python3 -m venv .venv
  fi

  sudo -u "${RUN_USER}" .venv/bin/pip install --upgrade pip
  sudo -u "${RUN_USER}" .venv/bin/pip install -r requirements.txt
}

seed_config_if_missing() {
  if [[ ! -f "${ETC_CONFIG}" && -f "${APP_DIR}/config.yml" ]]; then
    echo "Seeding ${ETC_CONFIG} from repo config.yml"
    cp "${APP_DIR}/config.yml" "${ETC_CONFIG}"
    chmod 644 "${ETC_CONFIG}"
  else
    echo "Config exists at ${ETC_CONFIG}, leaving it unchanged."
  fi
  
  # Ensure the app user owns the config directory and all contents
  chown -R "${RUN_USER}:${RUN_USER}" "${ETC_DIR}"
}

install_tailscale() {
  echo "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh

  echo
  read -rp "Enter Tailscale auth key: " TS_AUTHKEY < /dev/tty

  if [[ -n "${TS_AUTHKEY}" ]]; then
    tailscale up --authkey="${TS_AUTHKEY}" --ssh
    echo "Tailscale connected."
  else
    echo "No auth key provided. Run 'sudo tailscale up' manually after install."
  fi
}

install_audio_autoconfig() {
  echo "Installing USB audio auto-config helper..."

  cat > /usr/local/bin/mini-azaan-audio-autoconfig <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

OUT="/etc/asound.conf"

CARD_ID="$(awk '
  $0 ~ /: USB-Audio/ {
    for (i=1; i<=NF; i++) {
      if ($i ~ /^\[/) {
        gsub(/^\[/,"",$i)
        gsub(/\]:$/,"",$i)
        gsub(/\]$/,"",$i)
        print $i
        exit
      }
    }
  }
' /proc/asound/cards 2>/dev/null || true)"

if [[ -z "${CARD_ID}" ]]; then
  echo "No USB-Audio card detected. Leaving ${OUT} unchanged."
  exit 0
fi

# Use plug so ALSA can adapt sample rate / channels reliably
cat > "${OUT}" <<EOF_CONF
pcm.usb_hw {
  type hw
  card ${CARD_ID}
  device 0
}

pcm.usb {
  type plug
  slave.pcm "usb_hw"
}

pcm.!default {
  type plug
  slave.pcm "usb"
}

ctl.!default {
  type hw
  card ${CARD_ID}
}
EOF_CONF

chmod 644 "${OUT}"
echo "Configured ALSA default to USB card (with plug): ${CARD_ID}"
EOF

  chmod 755 /usr/local/bin/mini-azaan-audio-autoconfig
}

set_pcm_full_volume() {
  echo "Setting USB PCM mixer to 100% (hardware baseline)..."

  if ! command -v amixer >/dev/null 2>&1; then
    echo "amixer not found, skipping PCM volume set."
    return 0
  fi

  # If there are multiple USB devices, this uses the first USB-Audio card it finds.
  local card_index=""
  card_index="$(awk '
    $0 ~ /: USB-Audio/ {
      gsub(/^[[:space:]]*/,"",$1)
      print $1
      exit
    }
  ' /proc/asound/cards 2>/dev/null | tr -d ' ' || true)"

  if [[ -z "${card_index}" ]]; then
    echo "No USB-Audio detected yet, skipping PCM volume set."
    return 0
  fi

  # Only set if PCM control exists, to avoid errors on devices without it.
  if amixer -c "${card_index}" scontrols 2>/dev/null | grep -qi "^Simple mixer control 'PCM'"; then
    amixer -c "${card_index}" -q sset PCM 100% || true
    echo "Set card ${card_index} PCM to 100%."
  else
    echo "Card ${card_index} has no PCM mixer control, skipping."
  fi
}

install_systemd_service() {
  echo "Installing systemd unit: ${SERVICE_NAME}"

  cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=Mini Azaan Service
After=network-online.target sound.target time-sync.target
Wants=network-online.target sound.target time-sync.target

[Service]
Type=simple
User=${RUN_USER}
PermissionsStartOnly=true
WorkingDirectory=${APP_DIR}

ExecStartPre=/bin/sleep 2
ExecStartPre=/bin/bash -c 'if command -v timedatectl >/dev/null 2>&1; then for i in {1..30}; do timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes && exit 0; sleep 1; done; echo "NTP not synced yet, continuing"; fi; exit 0'
ExecStartPre=/bin/bash -c 'for i in {1..30}; do grep -qi "USB-Audio" /proc/asound/cards && exit 0; sleep 1; done; echo "USB-Audio not detected yet, starting anyway"; exit 0'
ExecStartPre=/usr/local/bin/mini-azaan-audio-autoconfig
ExecStartPre=/bin/bash -c 'amixer -c 0 sset PCM 100% || true'

ExecStart=${APP_DIR}/.venv/bin/python ${APP_DIR}/run_scheduler.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
}

install_web_service() {
  echo "Installing systemd unit: mini-azaan-web.service"

  cat > "/etc/systemd/system/mini-azaan-web.service" <<EOF
[Unit]
Description=Mini Azaan Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/.venv/bin/uvicorn web.app:app --host 0.0.0.0 --port 80
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable mini-azaan-web.service
}

allow_low_port() {
  echo "Granting Python permission to bind port 80..."
  local real_python
  real_python="$(readlink -f "${APP_DIR}/.venv/bin/python3")"
  setcap 'cap_net_bind_service=+ep' "${real_python}"
}

start_web_service() {
  echo "Starting web service..."
  systemctl restart mini-azaan-web.service
}

install_cli_link() {
  echo "Installing CLI..."

  if [[ ! -f "${APP_DIR}/manage.sh" ]]; then
    echo "manage.sh not found!"
    exit 1
  fi

  chmod 755 "${APP_DIR}/manage.sh"
  ln -sf "${APP_DIR}/manage.sh" "${BIN_LINK}"
  chmod 755 "${BIN_LINK}"
}

configure_sudoers() {
  echo "Configuring passwordless sudo for service management..."
  cat > /etc/sudoers.d/mini-azaan <<EOF
${RUN_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart mini-azaan.service, /usr/bin/systemctl status mini-azaan.service, /usr/local/bin/mini-azaan
EOF
  chmod 440 /etc/sudoers.d/mini-azaan
}

start_service() {
  echo "Starting service..."
  systemctl restart "${SERVICE_NAME}"
}

refresh_mdns() {
  systemctl enable avahi-daemon >/dev/null 2>&1 || true
  systemctl restart avahi-daemon >/dev/null 2>&1 || true
}

print_summary() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  echo
  echo "========================================"
  echo " Installation complete"
  echo " Log: ${LOG_FILE}"
  echo
  local ts_ip
  ts_ip="$(tailscale ip -4 2>/dev/null || true)"
  
  echo " Web UI:"
  echo "   http://${CONFIGURED_HOSTNAME:-$(hostname)}.local"
  echo " Hostname: ${CONFIGURED_HOSTNAME:-$(hostname)}"
  if [[ -n "${ip}" ]]; then
    echo " IP: ${ip}"
  fi
  if [[ -n "${ts_ip}" ]]; then
    echo " Tailscale IP: ${ts_ip}"
  fi
  echo
  echo " SSH:"
  echo "   ssh ${RUN_USER}@${CONFIGURED_HOSTNAME:-$(hostname)}.local"
  if [[ -n "${ip}" ]]; then
    echo "   ssh ${RUN_USER}@${ip}"
  fi
  echo
  echo " Service:"
  echo "   systemctl status ${SERVICE_NAME}"
  echo " Logs:"
  echo "   journalctl -u ${SERVICE_NAME} -f"
  echo " Installer log:"
  echo "   tail -f ${LOG_FILE}"
  echo "========================================"
  echo
}

main() {
  install_packages
  install_tailscale
  ensure_ssh_key
  prepare_dirs

  print_deploy_key
  wait_for_enter

  ensure_repo_with_retry
  configure_hostname

  setup_venv
  seed_config_if_missing

  install_audio_autoconfig
  # Configure ALSA then set hardware PCM high so app volume works as expected
  /usr/local/bin/mini-azaan-audio-autoconfig || true
  set_pcm_full_volume

  install_systemd_service
  install_web_service
  allow_low_port
  install_cli_link
  configure_sudoers
  start_service
  start_web_service
  refresh_mdns

  print_summary

  read -rp "Reboot now? (y/N): " CONFIRM < /dev/tty
  if [[ "${CONFIRM,,}" == "y" ]]; then
    echo "Rebooting..."
    reboot
  else
    echo "Skipping reboot. You can reboot later with: sudo reboot"
  fi
}

main