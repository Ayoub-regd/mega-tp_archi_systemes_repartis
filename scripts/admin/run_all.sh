#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="/vagrant"
ANSIBLE_SRC_DIR="${ROOT_DIR}/ansible"
ANSIBLE_DST_DIR="/home/vagrant/tp/ansible"
STATE_DIR="/home/vagrant/tp/.state"
LOG_DIR="/home/vagrant/tp/logs"
HOST_LOG_DIR="${ROOT_DIR}/scripts/logs/admin"
VENV_DIR="/home/vagrant/tp/.venv"
ANSIBLE_CORE_VERSION="${MEGATP_ANSIBLE_CORE_VERSION:-2.15.13}"
MEGATP_FORCE_VENV="${MEGATP_FORCE_VENV:-0}"
BOOTSTRAP_MARKER="${STATE_DIR}/bootstrap.ok"
GALAXY_MARKER="${STATE_DIR}/galaxy.sha256"
MEGATP_FORCE_GALAXY="${MEGATP_FORCE_GALAXY:-0}"
MEGATP_REFRESH_PACKAGES="${MEGATP_REFRESH_PACKAGES:-0}"
MEGATP_SKIP_GALAXY="${MEGATP_SKIP_GALAXY:-0}"
MEGATP_DEBUG="${MEGATP_DEBUG:-0}"

mkdir -p "${STATE_DIR}" "${LOG_DIR}"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/run_all_${RUN_ID}.log"
ANSIBLE_LOG_FILE="${LOG_DIR}/ansible_${RUN_ID}.log"

exec > >(tee -a "${LOG_FILE}") 2>&1
export ANSIBLE_LOG_PATH="${ANSIBLE_LOG_FILE}"
export ANSIBLE_NOCOLOR=1
export ANSIBLE_FORCE_COLOR=false

ts() { date -Is; }
info() { echo "[$(ts)] [INFO] $*"; }
warn() { echo "[$(ts)] [WARN] $*" >&2; }
fatal() { echo "[$(ts)] [FATAL] $*" >&2; exit 1; }

on_err() {
  local line="${1:-?}"
  local cmd="${2:-?}"
  local rc="${3:-1}"
  echo "[$(ts)] [FATAL] Echec (rc=${rc}) a la ligne ${line}: ${cmd}" >&2
  echo "[$(ts)] [FATAL] Log complet: ${LOG_FILE}" >&2
  echo "[$(ts)] [FATAL] Log Ansible: ${ANSIBLE_LOG_FILE}" >&2
  exit "${rc}"
}
trap 'on_err ${LINENO} "$BASH_COMMAND" $?' ERR

info "Log: ${LOG_FILE}"
info "Log Ansible: ${ANSIBLE_LOG_FILE}"
info "Logs persistants (host via /vagrant): ${HOST_LOG_DIR}"

persist_logs() {
  mkdir -p "${HOST_LOG_DIR}" 2>/dev/null || true
  cp -f "${LOG_FILE}" "${HOST_LOG_DIR}/" 2>/dev/null || true
  cp -f "${ANSIBLE_LOG_FILE}" "${HOST_LOG_DIR}/" 2>/dev/null || true
}
trap persist_logs EXIT

if [[ "${MEGATP_DEBUG}" == "1" ]]; then
  export PS4='[$(date -Is)] [DEBUG] '
  set -x
fi

wait_for_port() {
  local ip="${1}"
  local port="${2}"
  local retries="${3:-60}"
  local delay="${4:-5}"

  for _ in $(seq 1 "${retries}"); do
    if nc -z -w 2 "${ip}" "${port}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay}"
  done
  return 1
}

wait_for_ansible_ping() {
  local hostpattern="${1}"
  local module="${2}"
  local retries="${3:-30}"
  local delay="${4:-5}"

  for _ in $(seq 1 "${retries}"); do
    if ansible -i hosts "${hostpattern}" -m "${module}" -o >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay}"
  done
  return 1
}

wait_for_file() {
  local path="${1}"
  local retries="${2:-60}"
  local delay="${3:-5}"

  for _ in $(seq 1 "${retries}"); do
    if [[ -f "${path}" ]]; then
      return 0
    fi
    sleep "${delay}"
  done
  return 1
}

ensure_ansible_venv() {
  if [[ "${MEGATP_FORCE_VENV}" == "1" ]]; then
    warn "MEGATP_FORCE_VENV=1 -> suppression du venv ${VENV_DIR}"
    rm -rf "${VENV_DIR}" || true
  fi

  # Si une création précédente a échoué (ex: ensurepip absent), le venv peut être incomplet.
  if [[ -d "${VENV_DIR}" && ! -f "${VENV_DIR}/bin/activate" ]]; then
    warn "Venv incomplet détecté (activate manquant) -> rebuild ${VENV_DIR}"
    rm -rf "${VENV_DIR}" || true
  fi

  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    info "Création venv Python: ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  fi

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"

  python -m pip install --upgrade pip wheel

  local current_core=""
  current_core="$(ansible-playbook --version 2>/dev/null | head -n1 | sed -n 's/.*core \\([0-9.]*\\).*/\\1/p' || true)"
  if [[ "${current_core}" != "${ANSIBLE_CORE_VERSION}" ]]; then
    info "Installation ansible-core==${ANSIBLE_CORE_VERSION} (pip)"
    python -m pip install \
      "ansible-core==${ANSIBLE_CORE_VERSION}" \
      "pywinrm>=0.4.3,<0.5" \
      "requests-ntlm>=1,<2" \
      "pymysql>=1,<2"
  fi

  info "Ansible (venv): $(ansible-playbook --version | head -n1)"
}

galaxy_install_with_retry() {
  local max_attempts="${MEGATP_GALAXY_MAX_ATTEMPTS:-12}"
  local delay="${MEGATP_GALAXY_RETRY_DELAY_SEC:-10}"
  local attempt=1

  while true; do
    info "ansible-galaxy (tentative ${attempt}/${max_attempts})"
    if ansible-galaxy collection install "$@"; then
      return 0
    fi

    local rc=$?
    if (( attempt >= max_attempts )); then
      return "${rc}"
    fi

    warn "ansible-galaxy a échoué (rc=${rc}). Nouvelle tentative dans ${delay}s..."
    sleep "${delay}"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    if (( delay > 60 )); then
      delay=60
    fi
  done
}

collections_present() {
  local base="/home/vagrant/.ansible/collections/ansible_collections"
  local required=(
    "${base}/ansible/posix"
    "${base}/community/mysql"
    "${base}/ansible/windows"
    "${base}/community/zabbix"
  )

  for p in "${required[@]}"; do
    if [[ ! -d "${p}" ]]; then
      return 1
    fi
  done
  return 0
}

linux_only=false
if [[ "${1:-}" == "--linux-only" ]]; then
  linux_only=true
fi

if [[ ! -d "${ANSIBLE_SRC_DIR}" ]]; then
  fatal "Dossier Ansible introuvable: ${ANSIBLE_SRC_DIR}"
fi

needs_bootstrap=false
if [[ "${MEGATP_REFRESH_PACKAGES}" == "1" ]]; then
  needs_bootstrap=true
fi
for bin in python3 rsync curl nc sha256sum smbclient; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    needs_bootstrap=true
  fi
done
if ! python3 -m venv --help >/dev/null 2>&1; then
  needs_bootstrap=true
fi
if ! python3 -c "import ensurepip" >/dev/null 2>&1; then
  needs_bootstrap=true
fi

if [[ "${needs_bootstrap}" == "true" || ! -f "${BOOTSTRAP_MARKER}" ]]; then
  info "Bootstrap admin (paquets apt)"
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    python3-pip \
    rsync \
    curl \
    netcat-openbsd \
    smbclient
  date -Is > "${BOOTSTRAP_MARKER}"
else
  info "Bootstrap admin deja fait (skip apt). Pour forcer: MEGATP_REFRESH_PACKAGES=1"
fi

info "Bootstrap Ansible (venv)"
ensure_ansible_venv

info "Sync Ansible vers un dossier non world-writable (evite l'ignore ansible.cfg)"
sudo mkdir -p /home/vagrant/tp
sudo rsync -a --delete "${ANSIBLE_SRC_DIR}/" "${ANSIBLE_DST_DIR}/"
sudo chown -R vagrant:vagrant /home/vagrant/tp
chmod -R go-w "${ANSIBLE_DST_DIR}"

info "Installation des collections Ansible (versions pin)"
if [[ "${MEGATP_SKIP_GALAXY}" == "1" ]]; then
  if collections_present; then
    warn "MEGATP_SKIP_GALAXY=1 -> skip ansible-galaxy (collections déjà présentes)"
  else
    fatal "MEGATP_SKIP_GALAXY=1 mais collections absentes. Désactive MEGATP_SKIP_GALAXY ou installe les collections."
  fi
else
  req_file="${ANSIBLE_DST_DIR}/collections/requirements.yml"
  if [[ -f "${req_file}" ]]; then
    req_hash="$(sha256sum "${req_file}" | awk '{print $1}')"
    prev_hash="$(cat "${GALAXY_MARKER}" 2>/dev/null || true)"
    if [[ "${req_hash}" == "${prev_hash}" && "${MEGATP_FORCE_GALAXY}" != "1" ]] && collections_present; then
      info "requirements.yml inchangé + collections présentes (skip galaxy). Pour forcer: MEGATP_FORCE_GALAXY=1"
    else
      galaxy_args=(-r "${req_file}")
      if [[ "${MEGATP_FORCE_GALAXY}" == "1" ]]; then
        galaxy_args+=(--force)
      fi

      if galaxy_install_with_retry "${galaxy_args[@]}"; then
        echo "${req_hash}" > "${GALAXY_MARKER}"
      else
        fatal "ansible-galaxy a échoué après retries (Galaxy indisponible ?). Relance ou réessaie plus tard."
      fi
    fi
  else
    warn "requirements.yml introuvable, installation best-effort"
    galaxy_args=(ansible.posix community.mysql)
    if [[ "${MEGATP_FORCE_GALAXY}" == "1" ]]; then
      galaxy_args+=(--force)
    fi
    galaxy_install_with_retry "${galaxy_args[@]}" || fatal "ansible-galaxy best-effort a échoué"

    if [[ "${linux_only}" != "true" ]]; then
      galaxy_args=(ansible.windows:2.1.0 community.zabbix)
      if [[ "${MEGATP_FORCE_GALAXY}" == "1" ]]; then
        galaxy_args+=(--force)
      fi
      galaxy_install_with_retry "${galaxy_args[@]}" || fatal "ansible-galaxy best-effort (windows) a échoué"
    fi
  fi
fi

info "Recuperation des cles SSH Vagrant (pour node01/node02)"
install -d -m 700 -o vagrant -g vagrant /home/vagrant/.ssh
for node in node01 node02; do
  src_key="${ROOT_DIR}/.vagrant/machines/${node}/virtualbox/private_key"
  dst_key="/home/vagrant/.ssh/${node}.key"
  if [[ ! -f "${src_key}" ]]; then
    warn "Cle SSH non trouvee: ${src_key} (attente: creation VM ${node} en cours ?)"
    if ! wait_for_file "${src_key}" 120 5; then
      fatal "Cle SSH Vagrant introuvable: ${src_key}. Assure-toi que '${node}' est bien cree via 'vagrant up ${node}' sur l'hote."
    fi
  fi
  install -m 600 -o vagrant -g vagrant "${src_key}" "${dst_key}"
done

cd "${ANSIBLE_DST_DIR}"

info "Inventaire (graph)"
ansible-inventory -i hosts --graph

info "Attente SSH (node01/node02 sur 192.168.56.11/.12:22)"
for ip in 192.168.56.11 192.168.56.12; do
  if ! wait_for_port "${ip}" 22 60 5; then
    fatal "SSH non joignable sur ${ip}:22 (host-only). Verifie VirtualBox host-only et l'etat des VMs."
  fi
done

info "Sanity SSH (ping Ansible)"
if ! wait_for_ansible_ping "cluster" "ping" 30 5; then
  warn "Ansible ne peut pas joindre le cluster via SSH. Diagnostic detaille..."
  ansible -i hosts cluster -m ping -vv || true
  fatal "Arret: SSH/Ansible vers le cluster KO (inventory/cles)."
fi
ansible -i hosts cluster -m ping

info "Run playbook Linux"
ansible-playbook -i hosts site_linux.yml

info "Validations post-deploiement Linux"
bash "${ROOT_DIR}/scripts/admin/validate.sh"

if [[ "${linux_only}" == "false" ]]; then
  info "Attente WinRM (winsrv 192.168.56.13:5986)"
  if ! wait_for_port "192.168.56.13" 5986 360 5; then
    fatal "WinRM HTTPS non joignable depuis admin vers 192.168.56.13:5986 (IP host-only Windows / firewall / reboot sysprep)."
  fi

  if ! wait_for_ansible_ping "winsrv" "win_ping" 360 5; then
    warn "WinRM joignable mais Ansible win_ping echoue. Diagnostic detaille..."
    ansible -i hosts winsrv -m win_ping -vvv || true
    fatal "Arret: WinRM OK mais Ansible win_ping KO (auth/transport/inventory)."
  fi

  info "Run playbook Windows"
  ansible-playbook -i hosts site_windows.yml
  info "Validations post-deploiement Windows"
  bash "${ROOT_DIR}/scripts/admin/validate_windows.sh"
fi

info "Termine."
