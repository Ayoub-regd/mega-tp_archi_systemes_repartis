# soft_reset.ps1
Write-Host "=== 1. ARRÊT PROPRE DES MACHINES (Vagrant Halt) ===" -ForegroundColor Yellow
vagrant halt

Write-Host "=== 2. NETTOYAGE DES RÉSEAUX VIRTUALBOX (Anti-Conflit) ===" -ForegroundColor Yellow
$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$interfaces = & $VBoxManage list hostonlyifs

if ($interfaces) {
    # Extraction des noms d'interfaces
    $names = $interfaces | Select-String "Name:" | ForEach-Object { $_.ToString().Split(":")[1].Trim() }
    
    foreach ($name in $names) {
        Write-Host "   -> Suppression de l'interface : $name"
        # On supprime l'interface (peut échouer si encore utilisée, d'où l'arrêt avant)
        & $VBoxManage hostonlyif remove "$name" 2>$null
    }
} else {
    Write-Host "   -> Aucune interface parasite trouvée."
}

Write-Host "=== 3. RELANCE DU LABO (Vagrant Up) ===" -ForegroundColor Green
vagrant up

Write-Host "=== PRÊT ! Vos machines sont redémarrées sur un réseau propre. ===" -ForegroundColor Cyan