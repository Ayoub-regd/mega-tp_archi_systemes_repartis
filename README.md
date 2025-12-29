# Mega TP - Administration de systemes repartis (Vagrant + Ansible)

Objectif: deployer une infra 4 VM via un seul Vagrantfile, et tout configurer automatiquement (Ansible):
- HA Pacemaker/Corosync + VIP + Nginx + Samba
- Hardening Linux (firewalld, SSH root off, MAJ securite auto)
- Zabbix (server + agents + dashboard)
- Windows AD + hardening + LAPS

## Architecture

Schema Draw.io (editable):
- `docs/mega_tp_architecture.drawio`
- Export PNG: `docs/mega_tp_architecture-drawio.png`

![Schema Mega TP (Draw.io)](docs/mega_tp_architecture-drawio.png)

| VM | OS (box) | Role | IP host-only |
|---|---|---|---|
| `admin` | Ubuntu 22.04 (`generic/ubuntu2204`) | controleur Ansible + Zabbix Server | `192.168.56.10` |
| `node01` | AlmaLinux 9 (`generic/alma9`) | noeud cluster HA | `192.168.56.11` |
| `node02` | AlmaLinux 9 (`generic/alma9`) | noeud cluster HA | `192.168.56.12` |
| `winsrv` | Windows Server 2022 (`jborean93/WindowsServer2022`, v1.2.0) | AD + hardening + LAPS | `192.168.56.13` |

Reseau:
- 2 NIC par VM: NAT (Internet) + host-only `192.168.56.0/24`.
- VIP Pacemaker: `192.168.56.100` (bascule entre `node01`/`node02`).
- VIP HTTP: `http://192.168.56.100/`

## Prerequis (hote)

- OS: Windows 10/11 x86_64 (Intel/AMD). Boxes non ARM (Apple Silicon non supporte).
- VirtualBox 7.x + Vagrant 2.4+.
- Ressources conseillees: 12-16 Go RAM, 30+ Go libre.
- Reseau host-only VirtualBox en `192.168.56.0/24` (Vagrant le cree en general).
- Internet requis pour apt/yum/Ansible Galaxy.
- Si le plugin `vagrant-vbguest` est installe et provoque des erreurs, desactive-le ou desinstalle-le.

### Points d'attention (Windows)

- Fermer VirtualBox GUI et verifier qu'aucune VM ne tourne deja (`VBoxManage list runningvms`).
- Eviter de lancer en meme temps VMware Workstation, Hyper-V/WSL2 intensif, Docker Desktop ou d'autres outils de virtualisation (conflits/ralentissements possibles).
- Recommande: ajouter une exclusion antivirus sur le dossier du projet (evite des verrous/lenteurs sur les fichiers des VMs).
- Recommande: demarrer avec `vagrant up --no-parallel` pour eviter les timeouts/race conditions au boot (charge, reseau, WinRM).

Commandes utiles (PowerShell) pour verifier un hote "propre" avant `vagrant up`:

```powershell
Get-Process VirtualBoxVM,VBoxHeadless,VBoxSVC,vagrant,ruby -ErrorAction SilentlyContinue
VBoxManage list runningvms
```

## Demarrage 100% automatise

Depuis PowerShell (dans `mega-tp_final_en_cour`):
- `vagrant up --no-parallel`

Le provisionnement Ansible est declenche automatiquement sur `admin` (voir `Vagrantfile`).
Le demarrage est force en sequentiel pour eviter les timeouts (WinRM/SSH).
Windows (winsrv) peut etre tres lent au 1er boot (sysprep). Le `Vagrantfile` est configure pour attendre jusqu'a ~2h avant d'abandonner.

### Mode recommande (preflight Windows + demarrage sequentiel)

Pour un run plus "Julien-proof" (verifie les conflits classiques avant de lancer Vagrant):
- `.\scripts\run.ps1`

Par defaut, `run.ps1` verifie que des ports hote "classiques" (par defaut `2222,2223,2224`) ne sont pas deja en ecoute.
Important: comme le `Vagrantfile` ne fixe pas de forwarded ports SSH, Vagrant peut auto-corriger (ex: 2200/2201/2202/2203) si 2222 est occupe.
Options utiles:
- `.\scripts\run.ps1 -PreflightOnly` (ne demarre rien, verifie juste l'etat hote)
- `.\scripts\run.ps1 -SkipPortCheck` (accepte que Vagrant auto-corrige les ports)
- `.\scripts\run.ps1 -FailOnPortInUse` (mode strict: echoue si un port verifie est en ecoute)
- `.\scripts\run.ps1 -KillVirtualBoxProcesses` (arrete `VBoxHeadless/VirtualBoxVM/VBoxSVC` si des VM orphelines bloquent)
- `.\scripts\run.ps1 -RestartVirtualBoxNetwork` (necessite PowerShell en Administrateur)

### Linux only (debug)

Option 1 (PowerShell):
- `$env:MEGATP_LINUX_ONLY='1'; vagrant up node01 node02 admin; Remove-Item Env:MEGATP_LINUX_ONLY`

Option 2:
- `.\scripts\run.ps1 -LinuxOnly`

## Credentials (lab)

Ces valeurs sont des defaults de lab. A modifier si exige par le correcteur.

| Usage | Valeur |
|---|---|
| Linux SSH (node01/node02/admin) | user `vagrant` / password `vagrant` |
| Windows WinRM/RDP | user `vagrant` / password `vagrant` |
| Domaine AD | `corp.local` (NETBIOS `CORP`) |
| Domain Admin | `CORP\\Administrator` / password `vagrant` |
| DSRM (Safe Mode) | `MegaTP-DSRM-2025!` |
| Zabbix Web | `http://192.168.56.10/zabbix` - `Admin` / `zabbix` |
| MariaDB Zabbix | user `zabbix` / password `MegaTP-Zabbix-2025!` |
| Cluster hacluster | `MegaTP-HaCluster-2025!` |

Sources:
- `ansible/roles/windows_ad/defaults/main.yml`
- `ansible/roles/zabbix_server/defaults/main.yml`
- `ansible/roles/zabbix_config/defaults/main.yml`
- `ansible/roles/cluster_ha/defaults/main.yml`

## Validation (preuves "Julien-proof")

Linux:
- `vagrant ssh admin -c "bash /vagrant/scripts/admin/validate.sh"`
- `vagrant ssh admin -c "bash /vagrant/scripts/admin/validate.sh --failover --reboot-test"`

Windows:
- `vagrant ssh admin -c "bash /vagrant/scripts/admin/validate_windows.sh"`

## Captures pour le rendu (dans `docs/proofs/`)

Generation automatique (depuis l'hote, dans `mega-tp_final_en_cour`):
- `.\scripts\proofs\capture_proofs.ps1`
- `.\scripts\proofs\capture_proofs.ps1 -OpenZabbix` (ouvre Zabbix + VIP + dossier pour capture dashboard)

`capture_proofs.ps1` stocke les sorties "brutes" (horodatees) dans `docs/proofs/archive/<runid>/` (ignore par Git) et met a jour automatiquement:
- `docs/proofs/pcs_status.png`
- `docs/proofs/vip_page.png`

Si tu as capture des images ailleurs (ex: `docs\\proofs\\zabbix\\`), ou si tu veux ranger ton dossier local, lance:
- `.\scripts\proofs\finalize_proofs.ps1 -Archive`

Fichiers attendus:
- `docs/proofs/pcs_status.png`
- `docs/proofs/vip_page.png`
- `docs/proofs/zabbix_dashboard.png` (capture manuelle via navigateur)

Exemples:

![Cluster OK (pcs status --full)](docs/proofs/pcs_status.png)
![Page VIP (HTTP)](docs/proofs/vip_page.png)
![Dashboard Zabbix (MegaTP - Dashboard)](docs/proofs/zabbix_dashboard.png)

## Tests from scratch (clean run)

Si besoin de rejouer un test complet (recommande avant rendu):

```powershell
# 1) Aller dans le dossier du projet
cd "C:\\CHEMIN\\VERS\\mega-tp_final_en_cour"

# 2) Repartir de zero (ATTENTION: detruit toutes les VMs de ce projet)
vagrant destroy -f
Remove-Item -Recurse -Force .\\.vagrant -ErrorAction SilentlyContinue

# 3) Demarrer (recommande: sans parallele)
vagrant up --no-parallel

# 4) Lancer les validations
vagrant ssh admin -c "bash /vagrant/scripts/admin/validate.sh"
vagrant ssh admin -c "bash /vagrant/scripts/admin/validate_windows.sh"
```

### Depannage (winsrv / WinRM)

Si `vagrant up` echoue sur `winsrv` avec `Timed out while waiting for the machine to boot`, ce n'est pas forcement "casse". La VM Windows peut etre en train de finir son 1er boot (sysprep) ou un reboot.

1) Verifier l'etat:
- `vagrant status`
- `VBoxManage list runningvms`

2) Re-tenter uniquement Windows (sans tout detruire):

```powershell
vagrant up --no-parallel winsrv
```

3) Une fois `winsrv` OK, finir/relancer le provision `admin` (Ansible):

```powershell
vagrant up --no-parallel admin
vagrant provision admin
```

## Limites assumees (lab)

- "HA" = bascule logique (toutes les VM tournent sur le meme host).
- Samba HA sans stockage partage -> pas de garantie de coherence des donnees.

## Logs

- Logs horodates (run complet + Ansible): sur `admin` dans `/home/vagrant/tp/logs`.
- Copie automatique sur l'hote (shared folder): `scripts/logs/admin/`.
- `scripts/logs/` et `.vagrant/` sont ignores via `.gitignore`.

## Arborescence

- `Vagrantfile`: 4 VM + reseau + bootstrap WinRM + provision Ansible sur `admin`.
- `ansible/`: `site.yml`, `site_linux.yml`, `site_windows.yml`, `security.yml`, `windows.yml`, `hosts`, roles.
- `scripts/admin/run_all.sh`: bootstrap + execution Ansible (logs horodates + etat).
- `scripts/admin/validate.sh`: validations Linux (+ failover/reboot).
- `scripts/admin/validate_windows.sh`: validations Windows (AD/hardening/LAPS).

## References (docs officielles)

- Vagrant: https://developer.hashicorp.com/vagrant/docs
- VirtualBox: https://www.virtualbox.org/manual/UserManual.html
- Ansible: https://docs.ansible.com/
- Pacemaker/Corosync (RHEL): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/
- Zabbix: https://www.zabbix.com/documentation/current/en/manual
- Windows LAPS: https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-overview
