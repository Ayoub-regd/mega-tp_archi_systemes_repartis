# Mega TP Administration de systèmes répartis
# Multi-VM VirtualBox :
# - admin  (Ubuntu 22.04) : contrôleur Ansible + Zabbix Server
# - node01/node02 (AlmaLinux 9) : cluster Pacemaker/Corosync + VIP + Nginx + Samba
# - winsrv (Windows Server 2022) : AD + hardening (WinRM)
#
# Réseau host-only : 192.168.56.0/24
# VIP cluster : 192.168.56.100

# Fiabilisation : évite les démarrages en parallèle (pics RAM/CPU, timeouts WinRM/SSH).
# Vagrant lit cette variable au runtime et exécute alors les actions en séquentiel.
ENV["VAGRANT_NO_PARALLEL"] ||= "1"

Vagrant.configure("2") do |config|
  # Le shared folder VirtualBox est souvent lent/fragile sous Windows ; on l'active uniquement sur "admin".
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.box_check_update = false
  # Le 1er boot Windows (sysprep) + reboots AD peuvent dépasser 5 minutes.
  # On augmente le délai global pour éviter un `Timed out while waiting for the machine to boot`.
  config.vm.boot_timeout = 3600

  linux_only = ENV["MEGATP_LINUX_ONLY"] == "1"

  # Ordre important : on démarre d’abord les cibles (nodes/Windows), puis "admin" en dernier.
  nodes = {
    # NOTE: Bento (VirtIO-SCSI + EFI) a posé des problèmes de boot sur certains hôtes VirtualBox 7.2.x.
    # On revient sur des boxes "generic" (BIOS/SATA) qui ont déjà été validées sur ce poste.
    "node01" => { box: "generic/alma9", box_version: "4.3.12", ip: "192.168.56.11", memory: 1536, cpus: 2 },
    "node02" => { box: "generic/alma9", box_version: "4.3.12", ip: "192.168.56.12", memory: 1536, cpus: 2 },
    "winsrv" => { box: "jborean93/WindowsServer2022", box_version: "1.2.0", ip: "192.168.56.13", memory: 4096, cpus: 2 },
    "admin"  => { box: "generic/ubuntu2204", box_version: "4.3.12", ip: "192.168.56.10", memory: 2048, cpus: 2 }
  }

  nodes.each do |name, opts|
    config.vm.define name do |machine|
      machine.vm.box = opts[:box]
      machine.vm.box_version = opts[:box_version] if opts[:box_version]
      machine.vm.hostname = name

      # Windows: on désactive l'auto_config Vagrant pour éviter les erreurs WinRM/SSL pendant la config réseau.
      # L'IP host-only est appliquée par le provisioner PowerShell (winsrv_set_ip_winrm).
      if name == "winsrv"
        machine.vm.network "private_network", ip: opts[:ip], auto_config: false
      else
        machine.vm.network "private_network", ip: opts[:ip]
      end

      if name == "admin"
        machine.vm.synced_folder ".", "/vagrant", disabled: false

        # Déclenchement automatique Ansible (exigence "TOUT DOIT ETRE AUTOMATISE").
        # - par défaut: full (Linux + Windows)
        # - option: MEGATP_LINUX_ONLY=1 pour ne faire que Linux (debug/avancement)
        run_cmd = "bash /vagrant/scripts/admin/run_all.sh"
        run_cmd += " --linux-only" if linux_only
        machine.vm.provision "shell", name: "megatp_ansible", privileged: false, inline: run_cmd
      end

      machine.vm.provider "virtualbox" do |vb|
        vb.memory = opts[:memory]
        vb.cpus   = opts[:cpus]
        vb.linked_clone = true if vb.respond_to?(:linked_clone)

        # MAC déterministe UNIQUEMENT pour l'interface host-only Windows (réduit les renumérotations après reboot ADDS).
        # On ne force pas la MAC NAT: Vagrant la "match" au besoin pour rester compatible avec les boxes (NetworkManager peut lier des profils à la MAC).
        if name == "winsrv"
          last_octet = opts[:ip].split('.').last.to_i
          last_hex = last_octet.to_s(16).rjust(2, '0').upcase
          vb.customize ["modifyvm", :id, "--macaddress2", "0800275600#{last_hex}"]
        end
      end

      # Stabilisation Linux (VirtualBox 7.x + boxes avec Guest Additions 6.x peuvent être instables).
      # Les nœuds HA n'utilisent pas de shared folders => on peut désactiver vboxsf/vboxadd pour réduire le risque
      # de kernel panic (observé sur certains hôtes Windows/VirtualBox).
      if name == "node01" || name == "node02"
        machine.vm.provision "shell", name: "linux_stability", privileged: true, inline: <<-BASH
          set -euo pipefail

          # Ne pas bloquer si les services n'existent pas (selon l'image).
          systemctl disable --now vboxadd.service vboxadd-service.service 2>/dev/null || true
          systemctl mask vboxadd.service vboxadd-service.service 2>/dev/null || true

          # On ne monte aucun shared folder sur ces nœuds : blacklist vboxsf (cause fréquente de crash avec mismatch GA).
          cat >/etc/modprobe.d/megapt-blacklist-vboxsf.conf <<'EOF'
blacklist vboxsf
EOF

          # Si déjà chargé, on le retire (sinon noop).
          modprobe -r vboxsf 2>/dev/null || true
        BASH
      end

      if name == "winsrv"
        machine.vm.communicator = "winrm"

        # Identifiants de la box jborean93/WindowsServer2022 (VirtualBox) : vagrant/vagrant
        machine.winrm.username = "vagrant"
        machine.winrm.password = "vagrant"

        # WinRM côté Vagrant : Basic via TLS (HTTPS 5986).
        #
        # IMPORTANT :
        # - Vagrant se connecte via port-forward NAT (host -> guest), indépendant du host-only.
        # - Ansible pilote Windows via le réseau host-only (192.168.56.13:5986) (cf. ansible/hosts).
        # - Le 1er boot Windows (sysprep) peut être TRÈS long (selon disque/CPU). On augmente les timeouts WinRM.
        machine.winrm.transport = :ssl
        machine.winrm.basic_auth_only = true
        machine.winrm.ssl_peer_verification = false
        machine.winrm.guest_port = 5986
        # Certaines machines (sysprep au 1er boot) peuvent mettre >10 min avant un WinRM stable.
        # NOTE: Vagrant attend WinRM via `max_tries`/`retry_delay`.
        # On garde `retry_limit` par compat éventuelle, mais la valeur effective est `max_tries`.
        machine.winrm.max_tries = 720
        machine.winrm.retry_delay = 5
        machine.winrm.retry_limit = 720
        # Certains hôtes mettent >30 min avant que WinRM HTTPS soit réellement prêt.
        # Sur Vagrant 2.4.x, ce timeout permet d'éviter une sortie prématurée (valeur par défaut trop basse).
        machine.winrm.timeout = 3600 if machine.winrm.respond_to?(:timeout=)
        machine.vm.boot_timeout = 3600

        # Force une IP statique sur l’interface host-only (certaines boxes Windows ne prennent pas l’IP Vagrant correctement)
        # + ouvre ICMP/WinRM (lab).
        machine.vm.provision "shell", name: "winsrv_set_ip_winrm", inline: <<-PS
          $ErrorActionPreference = "Stop"

          $desiredIp = "192.168.56.13"
          $prefixLength = 24
          $hostOnlyAlias = "HostOnly"
          $remoteSubnet = "192.168.56.0/24"

          function Get-Ipv4([object]$cfg) {
            if ($cfg -and $cfg.IPv4Address -and $cfg.IPv4Address.IPAddress) { return $cfg.IPv4Address.IPAddress }
            return $null
          }

          function Is-Nat([object]$cfg) {
            $ip = Get-Ipv4 $cfg
            return ($null -ne $cfg.IPv4DefaultGateway) -or ($ip -and $ip -like "10.0.2.*")
          }

          # Détection host-only robuste:
          # - on force des MAC deterministes via VirtualBox (--macaddress2) pour éviter les renumérotations Windows
          # - on sélectionne donc l'interface host-only par MAC (même après reboot ADDS)
          $lastHex = ('{0:X2}' -f [int]($desiredIp.Split('.')[-1]))
          $expectedMac = "08-00-27-56-00-$lastHex"

          $targetAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.MacAddress -eq $expectedMac } | Select-Object -First 1
          if (-not $targetAdapter) {
            $targetAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.MacAddress -like "08-00-27-56-00-*" } | Select-Object -First 1
          }

          if ($targetAdapter) {
            $ifIndex = $targetAdapter.IfIndex
            $ifAlias = $targetAdapter.Name
          } else {
            # Fallback: interface UP qui n'est pas NAT (gateway/10.0.2.x)
            $ipConfigs = Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq "Up" }
            $target = $ipConfigs | Where-Object { -not (Is-Nat $_) } | Select-Object -First 1
            if (-not $target) { throw "Aucune interface réseau candidate (host-only) détectée" }
            $ifIndex = $target.InterfaceIndex
            $ifAlias = $target.InterfaceAlias
          }

          $cfg = Get-NetIPConfiguration -InterfaceIndex $ifIndex
          if (Is-Nat $cfg) {
            throw "Interface cible inattendue (probablement NAT): $ifAlias (ifIndex=$ifIndex). Abandon pour éviter de casser le réseau."
          }

          # Renommer l'interface host-only pour stabiliser les scripts (Windows peut renuméroter Ethernet 2/3 après ADDS)
          if ($ifAlias -ne $hostOnlyAlias) {
            try {
              Rename-NetAdapter -Name $ifAlias -NewName $hostOnlyAlias -Confirm:$false -ErrorAction Stop | Out-Null
              $ifAlias = $hostOnlyAlias
            } catch {}
          }

          # IP statique idempotente
          $existing = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $desiredIp }
          if (-not $existing) {
            # Ne supprime que des adresses non routées (APIPA) ou dans le /24 host-only attendu.
            Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -like "169.254.*" -or $_.IPAddress -like "192.168.56.*" } |
              Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $desiredIp -PrefixLength $prefixLength -ErrorAction Stop | Out-Null
          }

          # Network profile en Private (moins de restrictions lab)
          try { Set-NetConnectionProfile -InterfaceIndex $ifIndex -NetworkCategory Private -ErrorAction Stop } catch {}

          # Firewall: éviter les doublons (DisplayName)
          if (-not (Get-NetFirewallRule -DisplayName "MegaTP ICMPv4-In" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "MegaTP ICMPv4-In" -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow -Profile Any -RemoteAddress $remoteSubnet | Out-Null
          }
          if (-not (Get-NetFirewallRule -DisplayName "MegaTP WinRM" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "MegaTP WinRM" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985,5986 -Profile Any -RemoteAddress $remoteSubnet | Out-Null
          }

          # WinRM (on reste en HTTPS côté Ansible/Vagrant). Pas de plaintext en production.
          Set-Service WinRM -StartupType Automatic
          Start-Service WinRM
          winrm quickconfig -q
          try { Set-Item -Path WSMan:\\localhost\\Service\\Auth\\Basic -Value $true -ErrorAction Stop } catch {}

          # Assure un listener HTTPS (5986). Certaines séquences sysprep/ADDS peuvent supprimer/recréer les listeners.
          try {
            $haveHttps = Get-ChildItem WSMan:\\localhost\\Listener -ErrorAction SilentlyContinue |
              Where-Object { $_.Keys -match "Transport=HTTPS" } | Select-Object -First 1
            if (-not $haveHttps) {
              $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\\LocalMachine\\My
              New-WSManInstance -ResourceURI winrm/config/Listener `
                -SelectorSet @{Address="*";Transport="HTTPS"} `
                -ValueSet @{Hostname=$env:COMPUTERNAME;CertificateThumbprint=$cert.Thumbprint} | Out-Null
            }
          } catch {}

          # Persistance: tâche planifiée qui réapplique IP/Firewall au boot (ADDS = reboots = flakiness sinon).
          $baseDir = "C:\\ProgramData\\MegaTP"
          $taskScript = Join-Path $baseDir "ensure_hostonly.ps1"
          New-Item -Path $baseDir -ItemType Directory -Force | Out-Null

          $scriptContent = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$baseDir = "C:\\ProgramData\\MegaTP"
New-Item -Path $baseDir -ItemType Directory -Force | Out-Null
$log = Join-Path $baseDir "ensure_hostonly.log"

function Log([string]$msg) {
  try { Add-Content -Path $log -Value "$(Get-Date -Format o) $msg" } catch {}
}

try {
  $desiredIp = "192.168.56.13"
  $prefixLength = 24
  $hostOnlyAlias = "HostOnly"
  $remoteSubnet = "192.168.56.0/24"

  $lastHex = ('{0:X2}' -f [int]($desiredIp.Split('.')[-1]))
  $expectedMac = "08-00-27-56-00-$lastHex"
  Log "Start ensure_hostonly (expectedMac=$expectedMac)"

  # Après certains reboots (sysprep/ADDS), l'interface host-only peut mettre longtemps à passer UP.
  $deadline = (Get-Date).AddMinutes(60)
  $targetAdapter = $null

  while ((Get-Date) -lt $deadline -and -not $targetAdapter) {
    $targetAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.MacAddress -eq $expectedMac } | Select-Object -First 1
    if (-not $targetAdapter) {
      $targetAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.MacAddress -like "08-00-27-56-00-*" } | Select-Object -First 1
    }
    if (-not $targetAdapter) { Start-Sleep -Seconds 10 }
  }

  if (-not $targetAdapter) {
    Log "No host-only adapter detected (timeout). Exit."
    exit 0
  }

  $ifIndex = $targetAdapter.IfIndex
  $ifAlias = $targetAdapter.Name
  Log "Selected adapter: $ifAlias (ifIndex=$ifIndex, mac=$($targetAdapter.MacAddress))"

  # Renommer l'interface host-only pour stabiliser les scripts après reboot ADDS.
  if ($ifAlias -ne $hostOnlyAlias) {
    try {
      Rename-NetAdapter -Name $ifAlias -NewName $hostOnlyAlias -Confirm:$false | Out-Null
      $ifAlias = $hostOnlyAlias
      Log "Renamed to $hostOnlyAlias"
    } catch {
      Log "Rename failed: $($_.Exception.Message)"
    }
  }

  $existing = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $desiredIp }
  if (-not $existing) {
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -like "169.254.*" -or $_.IPAddress -like "192.168.56.*" } |
      Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $desiredIp -PrefixLength $prefixLength -ErrorAction SilentlyContinue | Out-Null
    Log "IP set: $desiredIp/$prefixLength"
  } else {
    Log "IP already set"
  }

  try { Set-NetConnectionProfile -InterfaceIndex $ifIndex -NetworkCategory Private } catch {}

  try {
    if (-not (Get-NetFirewallRule -DisplayName "MegaTP ICMPv4-In" -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName "MegaTP ICMPv4-In" -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow -Profile Any -RemoteAddress $remoteSubnet | Out-Null
      Log "Firewall ICMP rule created"
    }
    if (-not (Get-NetFirewallRule -DisplayName "MegaTP WinRM" -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName "MegaTP WinRM" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985,5986 -Profile Any -RemoteAddress $remoteSubnet | Out-Null
      Log "Firewall WinRM rule created"
    } else {
      Set-NetFirewallRule -DisplayName "MegaTP WinRM" -Enabled True -Profile Any | Out-Null
      Log "Firewall WinRM rule enabled"
    }
  } catch {
    Log "Firewall config error: $($_.Exception.Message)"
  }

  try {
    Set-Service WinRM -StartupType Automatic
    Start-Service WinRM
    winrm quickconfig -q
    try { Set-Item -Path WSMan:\\localhost\\Service\\Auth\\Basic -Value $true -ErrorAction Stop | Out-Null } catch {}
    Log "WinRM basic enabled"
  } catch {
    Log "WinRM config error: $($_.Exception.Message)"
  }

  try {
    $haveHttps = Get-ChildItem WSMan:\\localhost\\Listener -ErrorAction SilentlyContinue |
      Where-Object { $_.Keys -match "Transport=HTTPS" } | Select-Object -First 1
    if (-not $haveHttps) {
      $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\\LocalMachine\\My
      New-WSManInstance -ResourceURI winrm/config/Listener `
        -SelectorSet @{Address="*";Transport="HTTPS"} `
        -ValueSet @{Hostname=$env:COMPUTERNAME;CertificateThumbprint=$cert.Thumbprint} | Out-Null
      Log "HTTPS listener created"
    } else {
      Log "HTTPS listener exists"
    }
  } catch {
    Log "HTTPS listener error: $($_.Exception.Message)"
  }

  Log "Done"
} catch {
  Log "FATAL: $($_.Exception.Message)"
  exit 0
}
'@

          Set-Content -Path $taskScript -Value $scriptContent -Encoding UTF8 -Force

          $taskName = "MegaTP-EnsureHostOnly"
          $taskCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$taskScript`""
          $null = schtasks.exe /Create /F /RL HIGHEST /RU SYSTEM /SC ONSTART /TN $taskName /TR $taskCmd
          if ($LASTEXITCODE -ne 0) { throw "schtasks /Create a échoué (rc=$LASTEXITCODE)" }

          Write-Output "Configured host-only on $ifAlias (ifIndex=$ifIndex) => $desiredIp/$prefixLength"
          Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Format-List
        PS
      end
    end
  end
end


