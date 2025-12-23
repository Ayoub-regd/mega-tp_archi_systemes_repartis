# cleanup-vbox.ps1
# Tue tous les processus
Get-Process ruby, vagrant, VBoxHeadless, VBoxSVC -ErrorAction SilentlyContinue |
  Stop-Process -Force

# Liste et supprime toutes les VMs marquées <inaccessible>
$vms = VBoxManage list vms | Where-Object { $_ -match '<inaccessible>' }
foreach ($line in $vms) {
  if ($line -match '\{([0-9a-f-]+)\}') {
    $uuid = $matches[1]
    Write-Host "Unregister and delete VM $uuid"
    & VBoxManage unregistervm $uuid --delete
  }
}

# Prune Vagrant
vagrant box prune -f
