#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="mini-adhan.service"
APP_ROOT="/opt/mini-adhan"
APP_DIR="${APP_ROOT}/app"
ETC_DIR="/etc/mini-adhan"
ETC_CONFIG="${ETC_DIR}/config.yml"
BIN_LINK="/usr/local/bin/adhan"

GIT_REF="main"
VERSION_MODE=""
VERSION_TAG=""

GH_APP_ID="3076077"
GH_INSTALL_ID="115896741"
R2_ENDPOINT="https://a9ae43b7dc4de560ad084c65215e5250.r2.cloudflarestorage.com"
R2_BUCKET="mini-adhan-keys"
R2_KEY_ID="6a0af8f8642b95aa7176b403cfb2da01"
R2_SECRET_KEY="c355a5e341378ee41af2eea39b7dd8a33dd9d39c955d53daa2037516a8e86276"
R2_PEM_OBJECT="gh-app.pem"

PEM_FILE=""
GH_TOKEN=""

LOG_DIR="/var/log/mini-adhan"
LOG_FILE="${LOG_DIR}/install.log"

# Parse arguments
for arg in "$@"; do
  case "${arg}" in
    --pem=*) PEM_FILE="${arg#*=}" ;;
  esac
done

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
echo " Mini Adhan installer starting"
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
    echo "If you disconnect, reattach with: tmux attach -t mini-adhan-install"

    # Preserve args safely for the tmux command string
    args=""
    for a in "$@"; do
      args+=" $(printf "%q" "$a")"
    done

    exec tmux new -s mini-adhan-install "bash $(printf "%q" "$0")${args}"
  else
    echo "No interactive terminal detected. Skipping tmux auto-launch."
    echo "Tip: run this script from an SSH session for tmux protection."
  fi
fi

echo "Running inside tmux session: ${TMUX:-none}"
echo

echo "Installing Mini Adhan..."
echo

RUN_USER="${SUDO_USER:-pi}"
RUN_HOME="$(getent passwd "${RUN_USER}" | cut -d: -f6)"
if [[ -z "${RUN_HOME}" ]]; then
  echo "Could not resolve home directory for user: ${RUN_USER}"
  exit 1
fi

CONFIGURED_HOSTNAME=""

install_packages() {
  echo "Installing OS packages..."
  apt-get update
  apt-get install -y \
    git \
    python3 \
    python3-venv \
    python3-pip \
    libsdl2-mixer-2.0-0 \
    avahi-daemon \
    tmux \
    alsa-utils \
    dnsmasq-base
}

prepare_dirs() {
  echo "Preparing directories..."
  mkdir -p "${APP_ROOT}"
  mkdir -p "${ETC_DIR}"
  chown -R "${RUN_USER}:${RUN_USER}" "${APP_ROOT}"
}

configure_hostname() {
  echo
  read -rp "Enter device hostname (default: mini-adhan): " NEW_HOSTNAME < /dev/tty
  NEW_HOSTNAME=${NEW_HOSTNAME:-mini-adhan}

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

select_version() {
  echo
  echo "Which version would you like to install?"
  echo "  1) Latest stable release (recommended)"
  echo "  2) Specific version (e.g. v1.2.0)"
  echo "  3) Development branch (for testing)"
  read -rp "Choice [1]: " VERSION_CHOICE < /dev/tty
  VERSION_CHOICE=${VERSION_CHOICE:-1}

  case "${VERSION_CHOICE}" in
    1)
      VERSION_MODE="stable"
      GIT_REF="main"
      ;;
    2)
      VERSION_MODE="tag"
      GIT_REF="main"
      read -rp "Enter version (e.g. v1.2.0): " VERSION_TAG < /dev/tty
      if [[ -z "${VERSION_TAG}" ]]; then
        echo "No version specified, defaulting to latest stable release."
        VERSION_MODE="stable"
      fi
      ;;
    3)
      VERSION_MODE="dev"
      GIT_REF="dev"
      echo
      echo "Warning: Development branch — may be unstable."
      ;;
    *)
      echo "Invalid choice, defaulting to latest stable release."
      VERSION_MODE="stable"
      GIT_REF="main"
      ;;
  esac
  echo
}

download_pem_from_r2() {
  local dest="${1:-/tmp/gh-app.pem}"
  echo "Downloading PEM key from Cloudflare R2..."
  R2_KEY_ID="${R2_KEY_ID}" \
  R2_SECRET_KEY="${R2_SECRET_KEY}" \
  R2_ENDPOINT="${R2_ENDPOINT}" \
  R2_BUCKET="${R2_BUCKET}" \
  R2_PEM_OBJECT="${R2_PEM_OBJECT}" \
  DEST="${dest}" \
  python3 -c "
import hashlib, hmac, datetime, urllib.request, sys, os

key_id = os.environ['R2_KEY_ID']
secret = os.environ['R2_SECRET_KEY']
endpoint = os.environ['R2_ENDPOINT']
bucket = os.environ['R2_BUCKET']
obj = os.environ['R2_PEM_OBJECT']
dest = os.environ['DEST']

now = datetime.datetime.now(datetime.UTC)
datestamp = now.strftime('%Y%m%d')
amzdate = now.strftime('%Y%m%dT%H%M%SZ')
region = 'auto'
service = 's3'

def sign(key, msg):
    return hmac.new(key, msg.encode('utf-8'), hashlib.sha256).digest()

signing_key = sign(sign(sign(sign(('AWS4' + secret).encode('utf-8'), datestamp), region), service), 'aws4_request')

host = endpoint.replace('https://','')
uri = '/' + bucket + '/' + obj
headers_to_sign = 'host:' + host + '\nx-amz-content-sha256:UNSIGNED-PAYLOAD\nx-amz-date:' + amzdate + '\n'
signed_headers = 'host;x-amz-content-sha256;x-amz-date'
canonical = 'GET\n' + uri + '\n\n' + headers_to_sign + '\n' + signed_headers + '\nUNSIGNED-PAYLOAD'

scope = datestamp + '/' + region + '/' + service + '/aws4_request'
to_sign = 'AWS4-HMAC-SHA256\n' + amzdate + '\n' + scope + '\n' + hashlib.sha256(canonical.encode()).hexdigest()
signature = hmac.new(signing_key, to_sign.encode('utf-8'), hashlib.sha256).hexdigest()

auth = 'AWS4-HMAC-SHA256 Credential=' + key_id + '/' + scope + ', SignedHeaders=' + signed_headers + ', Signature=' + signature

req = urllib.request.Request(endpoint + uri, headers={
    'Authorization': auth,
    'x-amz-date': amzdate,
    'x-amz-content-sha256': 'UNSIGNED-PAYLOAD',
    'Host': host
})
try:
    data = urllib.request.urlopen(req).read()
    if b'BEGIN' not in data:
        print('ERROR: Downloaded file is not a valid PEM key', file=sys.stderr)
        sys.exit(1)
    with open(dest, 'wb') as f:
        f.write(data)
    print('PEM downloaded successfully.')
except Exception as e:
    print('ERROR: Failed to download PEM: ' + str(e), file=sys.stderr)
    sys.exit(1)
"
  if [[ $? -ne 0 ]]; then
    return 1
  fi
  PEM_FILE="${dest}"
}

resolve_pem_file() {
  # 1. --pem argument (already set)
  if [[ -n "${PEM_FILE}" && -f "${PEM_FILE}" ]]; then
    echo "Using PEM from argument: ${PEM_FILE}"
    return 0
  fi

  # 2. Existing install
  if [[ -f "${ETC_DIR}/gh-app.pem" ]]; then
    PEM_FILE="${ETC_DIR}/gh-app.pem"
    echo "Using PEM from previous install: ${PEM_FILE}"
    return 0
  fi

  # 3. Download from R2
  if download_pem_from_r2 "/tmp/gh-app.pem"; then
    PEM_FILE="/tmp/gh-app.pem"
    return 0
  fi

  # 4. Manual prompt
  echo
  read -rp "Path to GitHub App PEM file: " PEM_FILE < /dev/tty
  if [[ -n "${PEM_FILE}" && -f "${PEM_FILE}" ]]; then
    return 0
  fi

  echo "ERROR: No PEM file found. Cannot authenticate with GitHub."
  exit 1
}

get_github_token() {
  local pem_file="${1}"
  local app_id="${2:-${GH_APP_ID}}"
  local install_id="${3:-${GH_INSTALL_ID}}"

  local now_epoch
  now_epoch=$(date +%s)
  local iat=$((now_epoch - 30))
  local exp=$((now_epoch + 540))

  # JWT header and payload — use printf to avoid trailing newlines
  local header
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  local payload
  payload=$(printf '{"iss":"%s","iat":%d,"exp":%d}' "${app_id}" "${iat}" "${exp}" | openssl base64 -A | tr '+/' '-_' | tr -d '=')

  # Sign
  local signature
  signature=$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -sha256 -sign "${pem_file}" | openssl base64 -A | tr '+/' '-_' | tr -d '=')

  local jwt="${header}.${payload}.${signature}"

  # Request installation token
  local response
  response=$(curl -s -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${install_id}/access_tokens")

  GH_TOKEN=$(echo "${response}" | python3 -c "import json,sys; data=json.loads(sys.stdin.read()); print(data.get('token',''))" 2>/dev/null || true)

  if [[ -z "${GH_TOKEN}" ]]; then
    echo "ERROR: Failed to get GitHub installation token."
    echo "Response: ${response}"
    return 1
  fi
  echo "GitHub token obtained."
}

ensure_repo() {
  echo "Ensuring app repo is present at ${APP_DIR}..."

  resolve_pem_file
  get_github_token "${PEM_FILE}" || exit 1

  mkdir -p "${APP_ROOT}"
  chown -R "${RUN_USER}:${RUN_USER}" "${APP_ROOT}"

  local auth_url="https://x-access-token:${GH_TOKEN}@github.com/zukkybaig/mini-adhan.git"

  if [[ -d "${APP_DIR}/.git" ]]; then
    echo "Repo already exists, updating..."
    sudo -u "${RUN_USER}" git -C "${APP_DIR}" remote set-url origin "${auth_url}"
    sudo -u "${RUN_USER}" git -C "${APP_DIR}" fetch --all
    sudo -u "${RUN_USER}" git -C "${APP_DIR}" checkout "${GIT_REF}"
    sudo -u "${RUN_USER}" git -C "${APP_DIR}" pull
  else
    echo "Cloning repo..."
    rm -rf "${APP_DIR}"
    sudo -u "${RUN_USER}" git clone "${auth_url}" "${APP_DIR}"
    sudo -u "${RUN_USER}" git -C "${APP_DIR}" checkout "${GIT_REF}" || true
  fi

  # Clear token from remote URL after clone (security hygiene — token expires in 1hr anyway)
  sudo -u "${RUN_USER}" git -C "${APP_DIR}" remote set-url origin "https://github.com/zukkybaig/mini-adhan.git"
}

store_credentials() {
  echo "Storing credentials for future updates..."

  cp "${PEM_FILE}" "${ETC_DIR}/gh-app.pem"

  cat > "${ETC_DIR}/gh-app.conf" << EOF
GH_APP_ID=${GH_APP_ID}
GH_INSTALL_ID=${GH_INSTALL_ID}
R2_ENDPOINT=${R2_ENDPOINT}
R2_BUCKET=${R2_BUCKET}
R2_KEY_ID=${R2_KEY_ID}
R2_SECRET_KEY=${R2_SECRET_KEY}
R2_PEM_OBJECT=${R2_PEM_OBJECT}
EOF

  # Owned by RUN_USER so manage.sh can read them without sudo
  # (consistent with how /etc/mini-adhan/ is already handled — see seed_config_if_missing)
  chmod 600 "${ETC_DIR}/gh-app.pem"
  chmod 600 "${ETC_DIR}/gh-app.conf"
  chown -R "${RUN_USER}:${RUN_USER}" "${ETC_DIR}"

  echo "Credentials stored at ${ETC_DIR}/"
}

checkout_version() {
  case "${VERSION_MODE}" in
    stable)
      local latest_tag
      latest_tag=$(git -C "${APP_DIR}" describe --tags --abbrev=0 2>/dev/null || true)
      if [[ -n "${latest_tag}" ]]; then
        sudo -u "${RUN_USER}" git -C "${APP_DIR}" checkout "${latest_tag}"
        echo "Installed version: ${latest_tag}"
      else
        echo "No tags found, staying on ${GIT_REF} branch head."
      fi
      ;;
    tag)
      if git -C "${APP_DIR}" tag -l "${VERSION_TAG}" | grep -q "^${VERSION_TAG}$"; then
        sudo -u "${RUN_USER}" git -C "${APP_DIR}" checkout "${VERSION_TAG}"
        echo "Installed version: ${VERSION_TAG}"
      else
        echo "Tag '${VERSION_TAG}' not found. Available tags:"
        git -C "${APP_DIR}" tag -l | sort -V
        echo
        while true; do
          read -rp "Enter version (e.g. v1.2.0): " VERSION_TAG < /dev/tty
          if git -C "${APP_DIR}" tag -l "${VERSION_TAG}" | grep -q "^${VERSION_TAG}$"; then
            sudo -u "${RUN_USER}" git -C "${APP_DIR}" checkout "${VERSION_TAG}"
            echo "Installed version: ${VERSION_TAG}"
            break
          fi
          echo "Tag '${VERSION_TAG}' not found. Try again."
        done
      fi
      ;;
    dev)
      echo "Staying on dev branch head."
      ;;
  esac
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

install_system_files() {
  RUN_USER="${RUN_USER}" bash "${APP_DIR}/deploy/system-update.sh"
  # Configure ALSA then set hardware PCM high so app volume works as expected
  /usr/local/bin/mini-adhan-setup-alsa || true
  set_pcm_full_volume
  # Pre-create the AP profile so it's ready without NetworkManager needing to scan
  /usr/local/bin/mini-adhan-ap-mode create || true
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

allow_low_port() {
  echo "Granting Python permission to bind port 80..."
  local real_python
  real_python="$(readlink -f "${APP_DIR}/.venv/bin/python3")"
  setcap 'cap_net_bind_service=+ep' "${real_python}"
}

start_web_service() {
  echo "Starting web service..."
  systemctl restart mini-adhan-web.service
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

  local installed_version
  installed_version="$(git -C "${APP_DIR}" describe --tags --always 2>/dev/null || echo "unknown")"

  echo
  echo "========================================"
  echo " Installation complete"
  echo " Version: ${installed_version}"
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
  prepare_dirs
  configure_hostname
  select_version
  ensure_repo
  store_credentials
  checkout_version

  setup_venv
  seed_config_if_missing

  install_system_files

  allow_low_port
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
