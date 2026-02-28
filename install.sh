#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="mini-azaan.service"
APP_ROOT="/opt/mini-azaan"
APP_DIR="${APP_ROOT}/app"
ETC_DIR="/etc/mini-azaan"
ETC_CONFIG="${ETC_DIR}/config.yml"
BIN_LINK="/usr/local/bin/mini-azaan"

# Hardcoded private repo details
REPO_URL="git@github.com:zukkybaig/mini-azaan.git"
GIT_REF="main"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

echo "Installing Mini Azaan..."
echo "Repo: ${REPO_URL}"
echo "Branch: ${GIT_REF}"
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

install_packages() {
  echo "Installing OS packages..."
  apt-get update
  apt-get install -y git openssh-client openssh-server python3 python3-venv python3-pip mpg123 alsa-utils
}

ensure_ssh_key() {
  echo "Ensuring SSH deploy key exists for user: ${RUN_USER}"

  mkdir -p "${SSH_DIR}"
  chown "${RUN_USER}:${RUN_USER}" "${SSH_DIR}"
  chmod 700 "${SSH_DIR}"

  if [[ ! -f "${KEY_PATH}" || ! -f "${PUB_PATH}" ]]; then
    echo "Generating new SSH key..."
    sudo -u "${RUN_USER}" ssh-keygen -t ed25519 -N "" -f "${KEY_PATH}" -C "mini-azaan-${RUN_USER}@$(hostname)"
  else
    echo "SSH key already exists."
  fi

  sudo -u "${RUN_USER}" bash -c "ssh-keyscan -H github.com >> '${SSH_DIR}/known_hosts' 2>/dev/null || true"
  chown "${RUN_USER}:${RUN_USER}" "${SSH_DIR}/known_hosts" 2>/dev/null || true
  chmod 644 "${SSH_DIR}/known_hosts" 2>/dev/null || true
}

prompt_deploy_key() {
  echo
  echo "Add this public key to your GitHub repo Deploy Keys (read-only):"
  echo "Repo -> Settings -> Deploy keys -> Add deploy key"
  echo
  echo "----------------------------------------"
  cat "${PUB_PATH}"
  echo "----------------------------------------"
  echo
  echo "After adding it, press Enter to continue."
  read -r _
}

clone_repo() {
  echo "Creating directories..."
  mkdir -p "${APP_ROOT}"
  mkdir -p "${ETC_DIR}"

  echo "Cloning repo..."
  rm -rf "${APP_DIR}"

  if ! sudo -u "${RUN_USER}" git clone "${REPO_URL}" "${APP_DIR}"; then
    echo
    echo "Clone failed."
    echo "Make sure the deploy key was added correctly."
    echo "Public key:"
    cat "${PUB_PATH}"
    echo
    exit 1
  fi

  sudo -u "${RUN_USER}" git -C "${APP_DIR}" checkout "${GIT_REF}"
}

setup_venv() {
  echo "Setting up Python virtual environment..."
  cd "${APP_DIR}"

  sudo -u "${RUN_USER}" python3 -m venv .venv
  sudo -u "${RUN_USER}" .venv/bin/pip install -r requirements.txt
}

seed_config_if_missing() {
  if [[ ! -f "${ETC_CONFIG}" ]]; then
    if [[ -f "${APP_DIR}/config.yml" ]]; then
      echo "Seeding config to ${ETC_CONFIG}"
      cp "${APP_DIR}/config.yml" "${ETC_CONFIG}"
      chmod 644 "${ETC_CONFIG}"
    else
      echo "WARNING: No config.yml found in repo."
    fi
  else
    echo "Config already exists. Leaving it untouched."
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
  systemctl status "${SERVICE_NAME}" --no-pager || true
}

main() {
  install_packages
  ensure_ssh_key
  prompt_deploy_key
  clone_repo
  setup_venv
  seed_config_if_missing
  install_systemd_service
  install_cli_link
  start_service

  echo
  echo "Mini Azaan installed successfully."
  echo "Edit config:"
  echo "  sudo nano ${ETC_CONFIG}"
  echo "Use CLI:"
  echo "  mini-azaan status"
  echo "Logs:"
  echo "  journalctl -u ${SERVICE_NAME} -f"
}

main
