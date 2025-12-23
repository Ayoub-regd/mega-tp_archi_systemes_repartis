#!/usr/bin/env bash
set -euo pipefail

ANSIBLE_DIR="/home/vagrant/tp/ansible"
ANSIBLE_CMD="ansible"
ANSIBLE_VENV="/home/vagrant/tp/.venv/bin/ansible"
if [[ -x "${ANSIBLE_VENV}" ]]; then
  ANSIBLE_CMD="${ANSIBLE_VENV}"
fi

DOMAIN_NAME="${DOMAIN_NAME:-corp.local}"
LAPS_GPO_NAME="${LAPS_GPO_NAME:-MEGATP - LAPS}"
WIN_HOST="${WIN_HOST:-192.168.56.13}"
WIN_PORT="${WIN_PORT:-5986}"

if [[ ! -d "${ANSIBLE_DIR}" ]]; then
  echo "[FATAL] Dossier Ansible introuvable: ${ANSIBLE_DIR} (lance run_all.sh d'abord)" >&2
  exit 1
fi

cd "${ANSIBLE_DIR}"

wait_for_windows_network() {
  local max_wait="${1:-600}"
  local deadline="$((SECONDS + max_wait))"

  echo "[INFO] Attente réseau Windows (${WIN_HOST}) (max ${max_wait}s)"
  while (( SECONDS < deadline )); do
    if nc -z -w 2 "${WIN_HOST}" "${WIN_PORT}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

wait_for_win_ping() {
  local max_wait="${1:-900}"
  local deadline="$((SECONDS + max_wait))"

  echo "[INFO] Attente WinRM Ansible (win_ping) (max ${max_wait}s)"
  while (( SECONDS < deadline )); do
    if "${ANSIBLE_CMD}" -i hosts winsrv -m win_ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  return 1
}

run_win() {
  local cmd="${1}"
  "${ANSIBLE_CMD}" -i hosts winsrv -m win_shell -a "${cmd}" -o | tr -d '\r'
}

extract_stdout() {
  awk -F'\\(stdout\\) ' '{print $2}' | sed -E 's/[\\]r[\\]n//g; s/[\\]r//g; s/[\\]n//g; s/[[:space:]]+$//'
}

echo "[TEST] WinRM (win_ping)"
if ! wait_for_windows_network 1200; then
  echo "[FAIL] Windows injoignable sur ${WIN_HOST} (ping/port ${WIN_PORT})." >&2
  echo "       Indice: relance 'vagrant up winsrv' pour réappliquer l'IP host-only (provision winsrv_set_ip_winrm)." >&2
  exit 2
fi

if ! wait_for_win_ping 1800; then
  echo "[FAIL] WinRM joignable mais win_ping échoue (auth/transport/reboot AD en cours)." >&2
  "${ANSIBLE_CMD}" -i hosts winsrv -m win_ping -vvv || true
  exit 2
fi
echo "  OK"

echo "[TEST] AD: domaine joignable (${DOMAIN_NAME})"
out="$(run_win "Import-Module ActiveDirectory; (Get-ADDomain -Identity '${DOMAIN_NAME}').DNSRoot")"
echo "${out}"
value="$(printf '%s\n' "${out}" | extract_stdout)"
echo "${value}" | grep -qi "^${DOMAIN_NAME}$" || { echo "[FAIL] Get-ADDomain ne retourne pas ${DOMAIN_NAME}" >&2; exit 2; }
echo "  OK"

echo "[TEST] AD services (NTDS/DNS)"
out="$(run_win "(Get-Service -Name NTDS,DNS | ForEach-Object { '{0}={1}' -f \$_.Name, \$_.Status }) -join ','")"
echo "${out}"
value="$(printf '%s\n' "${out}" | extract_stdout)"
echo "${value}" | grep -q "NTDS=Running" || { echo "[FAIL] Service NTDS non running" >&2; exit 2; }
echo "${value}" | grep -q "DNS=Running"  || { echo "[FAIL] Service DNS non running" >&2; exit 2; }
echo "  OK"

echo "[TEST] Password policy (min 12 + complexité)"
out="$(run_win "Import-Module ActiveDirectory; \$p=Get-ADDefaultDomainPasswordPolicy -Identity '${DOMAIN_NAME}'; \"\$(\$p.MinPasswordLength),\$(\$p.ComplexityEnabled)\"")"
echo "${out}"
value="$(printf '%s\n' "${out}" | extract_stdout)"
min_len="${value%,*}"
complex="${value#*,}"
if [[ -z "${min_len}" || -z "${complex}" ]]; then
  echo "[FAIL] Impossible de lire la password policy (output inattendu: ${value})" >&2
  exit 2
fi
if [[ "${min_len}" -lt 12 || "${complex}" != "True" ]]; then
  echo "[FAIL] Password policy non conforme (MinLength=${min_len}, Complexity=${complex})" >&2
  exit 2
fi
echo "  OK"

echo "[TEST] SMBv1 désactivé"
out="$(run_win "(Get-SmbServerConfiguration).EnableSMB1Protocol")"
echo "${out}"
value="$(printf '%s\n' "${out}" | extract_stdout)"
echo "${value}" | grep -qi "^false$" || { echo "[FAIL] SMBv1 semble actif (EnableSMB1Protocol=${value})" >&2; exit 2; }
echo "  OK"

echo "[TEST] LLMNR désactivé (EnableMulticast=0)"
out="$(run_win "(Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\DNSClient' -Name EnableMulticast -ErrorAction SilentlyContinue).EnableMulticast")"
echo "${out}"
value="$(printf '%s\n' "${out}" | extract_stdout)"
echo "${value}" | grep -Eq "^0$" || { echo "[FAIL] LLMNR semble encore actif (EnableMulticast=${value})" >&2; exit 2; }
echo "  OK"

echo "[TEST] Firewall profiles activés (Domain/Private/Public)"
out="$(run_win "(Get-NetFirewallProfile -Profile Domain,Private,Public | Select -ExpandProperty Enabled) -join ','")"
echo "${out}"
value="$(printf '%s\n' "${out}" | extract_stdout)"
echo "${value}" | grep -q "^True,True,True$" || { echo "[FAIL] Pare-feu non activé sur tous les profils (${value})" >&2; exit 2; }
echo "  OK"

echo "[TEST] LAPS: schéma (msLAPS-PasswordExpirationTime) présent"
out="$(run_win "Import-Module ActiveDirectory; \$schemaNc=(Get-ADRootDSE).schemaNamingContext; (Get-ADObject -SearchBase \$schemaNc -LDAPFilter '(lDAPDisplayName=msLAPS-PasswordExpirationTime)').Name")"
echo "${out}"
value="$(printf '%s\n' "${out}" | extract_stdout)"
[[ -n "${value}" ]] || { echo "[FAIL] Attribut schéma LAPS introuvable" >&2; exit 2; }
echo "  OK"

echo "[TEST] LAPS: OU 'LAPS' existe"
out="$(run_win "Import-Module ActiveDirectory; \$dn=('${DOMAIN_NAME}'.Split('.') | ForEach-Object { 'DC=' + \$_ }) -join ','; (Get-ADOrganizationalUnit -LDAPFilter '(ou=LAPS)' -SearchBase \$dn).DistinguishedName")"
echo "${out}"
value="$(printf '%s\n' "${out}" | extract_stdout)"
echo "${value}" | grep -q "OU=LAPS" || { echo "[FAIL] OU LAPS introuvable" >&2; exit 2; }
echo "  OK"

echo "[TEST] LAPS: GPO '${LAPS_GPO_NAME}' existe"
out="$(run_win "Import-Module GroupPolicy; (Get-GPO -Name '${LAPS_GPO_NAME}' -ErrorAction Stop).DisplayName")"
echo "${out}"
value="$(printf '%s\n' "${out}" | extract_stdout)"
echo "${value}" | grep -q "^${LAPS_GPO_NAME}$" || { echo "[FAIL] GPO LAPS introuvable (${value})" >&2; exit 2; }
echo "  OK"

echo "[OK] Validations Windows terminées"
