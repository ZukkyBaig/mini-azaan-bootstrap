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
R2_SECRETS_OBJECT="secrets.enc"

PEM_FILE=""
TS_AUTHKEY=""
GH_TOKEN=""
CONFIGURED_HOSTNAME=""
VERSION_CHOICE=""
PROVISION_PASSWORD=""

LOG_DIR="/var/log/mini-adhan"
LOG_FILE="${LOG_DIR}/install.log"

# Parse arguments
for arg in "$@"; do
  case "${arg}" in
    --pem=*) PEM_FILE="${arg#*=}" ;;
    --ts-key=*) TS_AUTHKEY="${arg#*=}" ;;
    --hostname=*) CONFIGURED_HOSTNAME="${arg#*=}" ;;
    --version=*) VERSION_CHOICE="${arg#*=}" ;;
    --password=*) PROVISION_PASSWORD="${arg#*=}" ;;
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
  if [[ -z "${CONFIGURED_HOSTNAME}" ]]; then
    echo
    read -rp "Enter device hostname (default: mini-adhan): " CONFIGURED_HOSTNAME < /dev/tty
    CONFIGURED_HOSTNAME=${CONFIGURED_HOSTNAME:-mini-adhan}
  fi

  # Set hostname immediately on running system
  hostnamectl set-hostname "${CONFIGURED_HOSTNAME}"

  # Fix /etc/hosts
  if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${CONFIGURED_HOSTNAME}/" /etc/hosts
  else
    printf "127.0.1.1\t%s\n" "${CONFIGURED_HOSTNAME}" >> /etc/hosts
  fi

  # Disable cloud-init so it never stomps our config on reboot
  touch /etc/cloud/cloud-init.disabled

  echo
  echo "Device hostname configured as: ${CONFIGURED_HOSTNAME}"
  echo
}

select_version() {
  # If --version= was provided, resolve it without prompting
  if [[ -n "${VERSION_CHOICE}" ]]; then
    case "${VERSION_CHOICE}" in
      stable|1)
        VERSION_MODE="stable"
        GIT_REF="main"
        ;;
      dev|3)
        VERSION_MODE="dev"
        GIT_REF="dev"
        echo "Warning: Development branch — may be unstable."
        ;;
      v*)
        VERSION_MODE="tag"
        VERSION_TAG="${VERSION_CHOICE}"
        GIT_REF="main"
        ;;
      *)
        echo "Unknown version '${VERSION_CHOICE}', defaulting to stable."
        VERSION_MODE="stable"
        GIT_REF="main"
        ;;
    esac
    echo "Version: ${VERSION_MODE}${VERSION_TAG:+ ($VERSION_TAG)}"
    return
  fi

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

download_from_r2() {
  local object="${1}"
  local dest="${2}"
  R2_KEY_ID="${R2_KEY_ID}" \
  R2_SECRET_KEY="${R2_SECRET_KEY}" \
  R2_ENDPOINT="${R2_ENDPOINT}" \
  R2_BUCKET="${R2_BUCKET}" \
  R2_OBJECT="${object}" \
  DEST="${dest}" \
  python3 -c "
import hashlib, hmac, datetime, urllib.request, sys, os

key_id = os.environ['R2_KEY_ID']
secret = os.environ['R2_SECRET_KEY']
endpoint = os.environ['R2_ENDPOINT']
bucket = os.environ['R2_BUCKET']
obj = os.environ['R2_OBJECT']
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
    with open(dest, 'wb') as f:
        f.write(data)
except Exception as e:
    print('ERROR: Failed to download ' + obj + ': ' + str(e), file=sys.stderr)
    sys.exit(1)
"
}

download_and_decrypt_secrets() {
  local enc_dest="/tmp/secrets.enc"
  local tar_dest="/tmp/secrets.tar"
  local extract_dir="/tmp/mini-adhan-secrets"

  echo "Downloading encrypted secrets bundle from R2..."
  if ! download_from_r2 "${R2_SECRETS_OBJECT}" "${enc_dest}"; then
    return 1
  fi

  local attempts=0
  while [[ ${attempts} -lt 3 ]]; do
    if [[ -z "${PROVISION_PASSWORD}" ]]; then
      echo
      read -rsp "Enter provisioning password: " PROVISION_PASSWORD < /dev/tty
      echo
    fi

    if openssl enc -aes-256-cbc -pbkdf2 -d \
        -in "${enc_dest}" -out "${tar_dest}" \
        -pass "pass:${PROVISION_PASSWORD}" 2>/dev/null; then
      break
    fi

    attempts=$((attempts + 1))
    echo "Wrong password. (${attempts}/3)"
    PROVISION_PASSWORD=""
    if [[ ${attempts} -ge 3 ]]; then
      echo "ERROR: Too many failed attempts."
      rm -f "${enc_dest}" "${tar_dest}"
      exit 1
    fi
  done

  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  tar xf "${tar_dest}" -C "${extract_dir}"

  # Extract PEM
  if [[ -f "${extract_dir}/gh-app.pem" ]]; then
    PEM_FILE="/tmp/gh-app.pem"
    cp "${extract_dir}/gh-app.pem" "${PEM_FILE}"
  fi

  # Extract Tailscale key
  if [[ -f "${extract_dir}/tailscale-authkey.txt" ]]; then
    TS_AUTHKEY="$(cat "${extract_dir}/tailscale-authkey.txt" | tr -d '[:space:]')"
  fi

  # Cleanup
  rm -f "${enc_dest}" "${tar_dest}"
  rm -rf "${extract_dir}"

  # Validate
  if [[ -z "${PEM_FILE}" || ! -f "${PEM_FILE}" ]]; then
    echo "ERROR: Secrets bundle did not contain gh-app.pem."
    return 1
  fi
  if ! grep -q "BEGIN" "${PEM_FILE}" 2>/dev/null; then
    echo "ERROR: Extracted PEM is not valid."
    return 1
  fi

  echo "Secrets decrypted successfully."
}

resolve_secrets() {
  # PEM: --pem argument > existing install > secrets bundle
  if [[ -n "${PEM_FILE}" && -f "${PEM_FILE}" ]]; then
    echo "Using PEM from argument: ${PEM_FILE}"
  elif [[ -f "${ETC_DIR}/gh-app.pem" ]]; then
    PEM_FILE="${ETC_DIR}/gh-app.pem"
    echo "Using PEM from previous install: ${PEM_FILE}"
  fi

  # TS key: --ts-key argument > existing (not stored on disk, so only from arg)
  # If either is missing, download and decrypt the bundle
  if [[ -z "${PEM_FILE}" || ! -f "${PEM_FILE}" ]] || [[ -z "${TS_AUTHKEY}" ]]; then
    download_and_decrypt_secrets
  fi
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
R2_SECRETS_OBJECT=${R2_SECRETS_OBJECT}
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

  if [[ -n "${TS_AUTHKEY}" ]]; then
    tailscale up --authkey="${TS_AUTHKEY}" --hostname="${CONFIGURED_HOSTNAME}" --ssh
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
  prepare_dirs
  configure_hostname
  resolve_secrets
  install_tailscale
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
