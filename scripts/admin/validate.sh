#!/usr/bin/env bash
set -euo pipefail

ANSIBLE_DIR="/home/vagrant/tp/ansible"
ANSIBLE_CMD="ansible"
ANSIBLE_VENV="/home/vagrant/tp/.venv/bin/ansible"
if [[ -x "${ANSIBLE_VENV}" ]]; then
  ANSIBLE_CMD="${ANSIBLE_VENV}"
fi

failover_test=false
reboot_test=false

for arg in "$@"; do
  case "${arg}" in
    --failover) failover_test=true ;;
    --reboot-test) reboot_test=true ;;
    *) echo "[FATAL] Argument inconnu: ${arg}" >&2; exit 2 ;;
  esac
done

if [[ ! -d "${ANSIBLE_DIR}" ]]; then
  echo "[FATAL] Dossier Ansible introuvable: ${ANSIBLE_DIR} (lance run_all.sh d'abord)" >&2
  exit 1
fi

cd "${ANSIBLE_DIR}"

vip_ip="$(awk -F= '/^vip_ip=/{print $2}' hosts | tail -n1 | tr -d '\r' || true)"
vip_ip="${vip_ip:-192.168.56.100}"
vip_check_cmd="ip -4 -o addr show | grep -Fq '${vip_ip}/' && echo HAS_VIP || echo NO_VIP"
samba_share_name="${SMB_SHARE_NAME:-public}"

echo "[TEST] Connectivite Ansible -> cluster"
"${ANSIBLE_CMD}" -i hosts cluster -m ping >/dev/null
echo "  OK"

echo "[TEST] Services systeme HA (pcsd/corosync/pacemaker)"
"${ANSIBLE_CMD}" -i hosts cluster -b -m shell -a "systemctl is-active pcsd && systemctl is-active corosync && systemctl is-active pacemaker" >/dev/null
echo "  OK"

echo "[TEST] Cluster stable (2 noeuds online, pas de OFFLINE)"
"${ANSIBLE_CMD}" -i hosts node01 -b -m shell -a "pcs status --full | grep -Eq '^\\s*\\* Node node01 .*: online' && pcs status --full | grep -Eq '^\\s*\\* Node node02 .*: online' && ! pcs status --full | grep -q 'OFFLINE'" >/dev/null
"${ANSIBLE_CMD}" -i hosts node01 -b -m shell -a "pcs status --full | grep -q 'HA-GRP'" >/dev/null
echo "  OK"

echo "[TEST] VIP presente sur un seul noeud"
vip_report="$("${ANSIBLE_CMD}" -i hosts cluster -b -m shell -a "${vip_check_cmd}" -o | tr -d '\r')"
echo "${vip_report}"

vip_count="$(echo "${vip_report}" | grep -c 'HAS_VIP' || true)"
if [[ "${vip_count}" -ne 1 ]]; then
  echo "[FAIL] VIP ${vip_ip} attendue sur 1 seul noeud, trouvee: ${vip_count}" >&2
  exit 2
fi
echo "  OK"

echo "[TEST] HTTP sur VIP (Nginx en HA)"
curl -fsS "http://${vip_ip}/" | grep -q "MegaTP HA OK"
echo "  OK"

echo "[TEST] SMB sur VIP (Samba en HA)"
if command -v smbclient >/dev/null 2>&1; then
  smbclient -N "//${vip_ip}/${samba_share_name}" -c "ls" >/dev/null
else
  nc -zv -w 3 "${vip_ip}" 445 >/dev/null
fi
echo "  OK"

if [[ "${failover_test}" == "true" ]]; then
  echo "[TEST] Failover (pcs node standby/unstandby)"
  vip_holder="$(echo "${vip_report}" | awk '/HAS_VIP/{print $1; exit}' | tr -d '\r')"
  if [[ -z "${vip_holder}" ]]; then
    echo "[FAIL] Impossible d'identifier le noeud qui porte la VIP" >&2
    exit 2
  fi

  other_node=""
  for n in node01 node02; do
    if [[ "${n}" != "${vip_holder}" ]]; then other_node="${n}"; fi
  done
  if [[ -z "${other_node}" ]]; then
    echo "[FAIL] Impossible d'identifier le noeud de bascule" >&2
    exit 2
  fi

  echo "  -> VIP sur ${vip_holder}, standby puis attente bascule vers ${other_node}"
  "${ANSIBLE_CMD}" -i hosts node01 -b -m shell -a "pcs node standby ${vip_holder}" >/dev/null

  moved=false
  for _ in $(seq 1 30); do
    sleep 2
    vip_report2="$("${ANSIBLE_CMD}" -i hosts cluster -b -m shell -a "${vip_check_cmd}" -o | tr -d '\r')"
    if echo "${vip_report2}" | grep -q "^${other_node} .*HAS_VIP"; then
      moved=true
      break
    fi
  done

  # Toujours retablir le noeud, meme en cas d'echec du test
  "${ANSIBLE_CMD}" -i hosts node01 -b -m shell -a "pcs node unstandby ${vip_holder}" >/dev/null || true

  if [[ "${moved}" != "true" ]]; then
    echo "[FAIL] La VIP n'a pas bascule vers ${other_node} dans le delai attendu" >&2
    exit 2
  fi

  echo "  OK"
fi

if [[ "${reboot_test}" == "true" ]]; then
  echo "[TEST] Reboot test (noeud passif)"
  vip_holder="$(echo "${vip_report}" | awk '/HAS_VIP/{print $1; exit}' | tr -d '\r')"
  passive_node=""
  for n in node01 node02; do
    if [[ "${n}" != "${vip_holder}" ]]; then passive_node="${n}"; fi
  done
  if [[ -z "${passive_node}" ]]; then
    echo "[FAIL] Impossible d'identifier le noeud passif" >&2
    exit 2
  fi

  echo "  -> reboot ${passive_node} (VIP reste sur ${vip_holder})"
  "${ANSIBLE_CMD}" -i hosts "${passive_node}" -b -m reboot -a "reboot_timeout=600" >/dev/null

  echo "  -> verification cluster apres reboot"
  "${ANSIBLE_CMD}" -i hosts node01 -b -m shell -a "pcs status --full | grep -Eq '^\\s*\\* Node node01 .*: online' && pcs status --full | grep -Eq '^\\s*\\* Node node02 .*: online' && ! pcs status --full | grep -q 'OFFLINE'" >/dev/null

  vip_report="$("${ANSIBLE_CMD}" -i hosts cluster -b -m shell -a "${vip_check_cmd}" -o | tr -d '\r')"
  vip_count="$(echo "${vip_report}" | grep -c 'HAS_VIP' || true)"
  if [[ "${vip_count}" -ne 1 ]]; then
    echo "[FAIL] VIP ${vip_ip} dupliquee apres reboot (count=${vip_count})" >&2
    exit 2
  fi
  echo "  OK"
fi

echo "[TEST] Ports firewall (lecture + sanity)"
fw_ports="$("${ANSIBLE_CMD}" -i hosts cluster -b -m shell -a "firewall-cmd --list-ports" -o | tr -d '\r')"
echo "${fw_ports}"
echo "${fw_ports}" | grep -q "2224/tcp"  || { echo "[FAIL] Port pcsd 2224/tcp non ouvert" >&2; exit 2; }
echo "${fw_ports}" | grep -q "5405/udp"  || { echo "[FAIL] Port corosync 5405/udp non ouvert" >&2; exit 2; }
echo "${fw_ports}" | grep -q "80/tcp"    || { echo "[FAIL] Port HTTP 80/tcp non ouvert" >&2; exit 2; }
echo "${fw_ports}" | grep -q "10050/tcp" || { echo "[FAIL] Port zabbix-agent 10050/tcp non ouvert" >&2; exit 2; }
echo "${fw_ports}" | grep -q "445/tcp"   || { echo "[FAIL] Port Samba 445/tcp non ouvert" >&2; exit 2; }
echo "  OK"

echo "[TEST] dnf-automatic timer"
"${ANSIBLE_CMD}" -i hosts cluster -b -m shell -a "systemctl is-enabled dnf-automatic.timer && systemctl is-active dnf-automatic.timer" >/dev/null
echo "  OK"

echo "[TEST] Zabbix server (services + HTTP)"
sudo systemctl is-active mariadb apache2 zabbix-server >/dev/null
if [[ ! -f /etc/zabbix/web/zabbix.conf.php ]]; then
  echo "[FAIL] Zabbix frontend non configure: /etc/zabbix/web/zabbix.conf.php manquant" >&2
  exit 2
fi
code="$(curl -sS -o /dev/null -w '%{http_code}' http://localhost/zabbix/ || true)"
if [[ "${code}" != "200" && "${code}" != "302" ]]; then
  echo "[FAIL] Zabbix UI non joignable (HTTP ${code})" >&2
  exit 2
fi
echo "  OK"

echo "[TEST] Zabbix API + objets (hosts/vip/dashboard)"
ZABBIX_API_URL="${ZABBIX_API_URL:-http://localhost/zabbix/api_jsonrpc.php}"
ZABBIX_USER="${ZABBIX_USER:-Admin}"
ZABBIX_PASSWORD="${ZABBIX_PASSWORD:-zabbix}"
ZABBIX_DASHBOARD_NAME="${ZABBIX_DASHBOARD_NAME:-MegaTP - Dashboard}"
VIP_HOST="${VIP_HOST:-vip}"
VIP_ITEM_KEY="${VIP_ITEM_KEY:-net.tcp.service[http,,80]}"

python3 - <<'PY'
import json
import os
import sys
import time
import urllib.request

api_url = os.getenv("ZABBIX_API_URL", "http://localhost/zabbix/api_jsonrpc.php")
user = os.getenv("ZABBIX_USER", "Admin")
password = os.getenv("ZABBIX_PASSWORD", "zabbix")
dash_name = os.getenv("ZABBIX_DASHBOARD_NAME", "MegaTP - Dashboard")
vip_host = os.getenv("VIP_HOST", "vip")
vip_item_key = os.getenv("VIP_ITEM_KEY", "net.tcp.service[http,,80]")
max_wait = int(os.getenv("ZABBIX_AGENT_WAIT_SEC", "300"))
poll_interval = int(os.getenv("ZABBIX_AGENT_POLL_SEC", "10"))

def call(method, params=None, auth=None, _id=1):
    if params is None:
        params = {}
    body = {"jsonrpc": "2.0", "method": method, "params": params, "id": _id}
    if auth:
        body["auth"] = auth
    data = json.dumps(body).encode()
    req = urllib.request.Request(api_url, data=data, headers={"Content-Type": "application/json-rpc"})
    with urllib.request.urlopen(req, timeout=10) as response:
        payload = json.load(response)
    if "error" in payload:
        raise RuntimeError(f"Zabbix API error: {payload['error']}")
    return payload["result"]

version = call("apiinfo.version")
auth = call("user.login", {"user": user, "password": password})

def get_hosts():
    return call(
        "host.get",
        {
            "output": ["hostid", "host"],
            "filter": {"host": ["node01", "node02", vip_host]},
            "selectInterfaces": ["available", "error"],
        },
        auth=auth,
    )

hosts = get_hosts()
host_names = {h["host"] for h in hosts}
missing = {"node01", "node02", vip_host} - host_names
if missing:
    raise RuntimeError(f"Hosts manquants dans Zabbix: {sorted(missing)}")

# Zabbix met du temps a rafraichir l'etat "available" apres un reboot.
# On attend un peu avant d'echouer, sinon on a des faux negatifs.
deadline = time.time() + max_wait
while True:
    bad = []
    for h in hosts:
        if h["host"] in ("node01", "node02"):
            iface = (h.get("interfaces") or [{}])[0]
            if iface.get("available") != "1":
                bad.append((h["host"], iface.get("available"), iface.get("error")))
    if not bad:
        break
    if time.time() >= deadline:
        details = ", ".join([f"{name}(available={avail}, err={err!r})" for name, avail, err in bad])
        raise RuntimeError(f"Agents Zabbix indisponibles apres attente ({max_wait}s): {details}")
    time.sleep(poll_interval)
    hosts = get_hosts()

vip_hostid = [h["hostid"] for h in hosts if h["host"] == vip_host][0]
vip_items = call("item.get", {"output": ["lastvalue", "lastclock"], "hostids": [vip_hostid], "filter": {"key_": [vip_item_key]}}, auth=auth)
if not vip_items:
    raise RuntimeError(f"Item VIP introuvable: {vip_item_key}")

item = vip_items[0]
if item.get("lastvalue") != "1":
    raise RuntimeError(f"VIP HTTP check KO (lastvalue={item.get('lastvalue')})")

age = int(time.time()) - int(item.get("lastclock", "0") or "0")
if age > 180:
    raise RuntimeError(f"VIP HTTP check trop ancien (age={age}s)")

dash = call("dashboard.get", {"output": ["dashboardid", "name"], "filter": {"name": [dash_name]}}, auth=auth)
if not dash:
    raise RuntimeError(f"Dashboard introuvable: {dash_name}")

print(f"OK (zabbix {version})")
PY
echo "  OK"

echo "[TEST] Zabbix agents (services + port)"
"${ANSIBLE_CMD}" -i hosts cluster -b -m shell -a "systemctl is-active zabbix-agent && ss -lntp | grep -q ':10050'" >/dev/null
echo "  OK"

echo "[OK] Validations Linux terminees"
