#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="mini-azaan.service"
APP_ROOT="/opt/mini-azaan"
APP_DIR="${APP_ROOT}/app"
ETC_DIR="/etc/mini-azaan"
ETC_CONFIG="${ETC_DIR}/config.yml"
BIN_LINK="/usr/local/bin/mini-azaan"

# Hardcoded private repo
REPO_URL="git@github.com:zukkybaig/mini-azaan.git"
GIT_REF="main"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

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
  apt-get install -y git openssh-client openssh-server python3 python3-venv python3-pip mpg123 alsa-utils avahi-daemon
}

ensure_ssh_key() {
  echo "Ensuring SSH deploy key exists..."

  mkdir -p "${SSH_DIR}"
  chown "${RUN_USER}:${RUN_USER}" "${SSH_DIR}"
  chmod 700 "${SSH_DIR}"

  if [[ ! -f "${KEY_PATH}" ]]; then
    sudo -u "${RUN_USER}" ssh-keygen -t ed25519 -N "" -f "${KEY_PATH}" -C "mini-azaan-${RUN_USER}@$(hostname)"
  fi

  sudo -u "${RUN_USER}" bash -c "ssh-keyscan -H github.com >> '${SSH_DIR}/known_hosts' 2>/dev/null || true" || true
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
  echo "Tip: read-only is fine"
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
  echo "Hostname helps you identify this device on the network."
  read -rp "Enter device hostname (default: mini-azaan): " NEW_HOSTNAME < /dev/tty
  NEW_HOSTNAME=${NEW_HOSTNAME:-mini-azaan}

  USER_DATA="/boot/firmware/user-data"

  if [[ -f "${USER_DATA}" ]]; then
    if grep -qE '^[[:space:]]*hostname:' "${USER_DATA}"; then
      sed -i -E "s/^[[:space:]]*hostname:.*/hostname: ${NEW_HOSTNAME}/" "${USER_DATA}"
    else
      printf "\nhostname: %s\n" "${NEW_HOSTNAME}" >> "${USER_DATA}"
    fi
  else
    echo "WARNING: ${USER_DATA} not found. Hostname will not be persisted via cloud-init."
  fi

  CONFIGURED_HOSTNAME="${NEW_HOSTNAME}"

  echo
  echo "========================================"
  echo " Device hostname configured as:"
  echo "   ${CONFIGURED_HOSTNAME}"
  echo
  echo " After reboot you can SSH using:"
  echo "   ssh ${RUN_USER}@${CONFIGURED_HOSTNAME}.local"
  echo "========================================"
  echo
}

clone_repo_once() {
  rm -rf "${APP_DIR}"
  sudo -u "${RUN_USER}" git clone "${REPO_URL}" "${APP_DIR}"
}

clone_repo_with_retry() {
  echo "Cloning private repo..."

  while true; do
    if clone_repo_once; then
      sudo -u "${RUN_USER}" git -C "${APP_DIR}" checkout "${GIT_REF}" || true
      echo "Clone succeeded."
      break
    fi

    echo
    echo "Clone failed."
    echo "If SSH auth is fine, this is usually permissions or deploy key not added."
    print_deploy_key
    wait_for_enter
    echo "Retrying clone..."
  done
}

setup_venv() {
  echo "Setting up virtual environment..."
  cd "${APP_DIR}"
  sudo -u "${RUN_USER}" python3 -m venv .venv
  sudo -u "${RUN_USER}" .venv/bin/pip install -r requirements.txt
}

seed_config_if_missing() {
  if [[ ! -f "${ETC_CONFIG}" && -f "${APP_DIR}/config.yml" ]]; then
    cp "${APP_DIR}/config.yml" "${ETC_CONFIG}"
    chmod 644 "${ETC_CONFIG}"
  fi
}

install_systemd_service() {
  echo "Installing systemd service..."

  cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=Mini Azaan Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/.venv/bin/python ${APP_DIR}/main.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
}

install_cli_link() {
  echo "Installing CLI shortcut..."
  chmod +x "${APP_DIR}/manage.sh" || true
  ln -sf "${APP_DIR}/manage.sh" "${BIN_LINK}"
}

start_service() {
  echo "Starting service..."
  systemctl restart "${SERVICE_NAME}"
}

print_device_info() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  echo
  echo "========================================"
  echo " Install complete"
  echo
  echo " Hostname: ${CONFIGURED_HOSTNAME:-$(hostname)}"
  if [[ -n "${ip}" ]]; then
    echo " IP Address: ${ip}"
  else
    echo " IP Address: (unknown)"
  fi
  echo
  echo " SSH:"
  echo "   ssh ${RUN_USER}@${CONFIGURED_HOSTNAME}.local"
  if [[ -n "${ip}" ]]; then
    echo "   ssh ${RUN_USER}@${ip}"
  fi
  echo
  echo " Service:"
  echo "   systemctl status ${SERVICE_NAME}"
  echo " Logs:"
  echo "   journalctl -u ${SERVICE_NAME} -f"
  echo "========================================"
  echo
}

health_check_service() {
  echo "Checking service status..."
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "Service is running."
  else
    echo "Service is not running. Showing status:"
    systemctl status "${SERVICE_NAME}" --no-pager || true
    echo
    echo "Showing last 60 log lines:"
    journalctl -u "${SERVICE_NAME}" -n 60 --no-pager || true
  fi
}

refresh_mdns() {
  echo "Refreshing mDNS announcement (avahi)..."
  systemctl enable avahi-daemon >/dev/null 2>&1 || true
  systemctl restart avahi-daemon >/dev/null 2>&1 || true
}

main() {
  install_packages
  ensure_ssh_key
  prepare_dirs

  print_deploy_key
  wait_for_enter

  clone_repo_with_retry
  configure_hostname

  setup_venv
  seed_config_if_missing
  install_systemd_service
  install_cli_link
  start_service

  refresh_mdns
  health_check_service
  print_device_info

  echo "A reboot is recommended to apply the new hostname everywhere."
  echo "You can reboot later manually with: sudo reboot"
  echo

  read -rp "Reboot now? (y/N): " CONFIRM < /dev/tty
  if [[ "${CONFIRM,,}" == "y" ]]; then
    echo "Rebooting..."
    reboot
  else
    echo "Skipping reboot. Remember to reboot manually."
  fi
}

main