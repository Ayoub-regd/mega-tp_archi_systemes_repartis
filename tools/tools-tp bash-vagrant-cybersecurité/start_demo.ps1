# ==============================================================================
# SCRIPT : DÃ‰MARRAGE DÃ‰MO
# EMPLACEMENT : /tools/
# ==============================================================================

# 1. FIX CRITIQUE : On se place Ã  la racine du projet
Set-Location (Resolve-Path "C:\Users\ayoub\Travail-Bash-sur-vagrant\projet-bash-vagrant-final\projet-cybersecurite\..")
Write-Host "ðŸ“‚ Contexte dÃ©fini sur : C:\Users\ayoub\Travail-Bash-sur-vagrant\projet-bash-vagrant-final\projet-cybersecurite" -ForegroundColor Gray

# 2. PRÃ‰PARATION
Write-Host "--- PRÃ‰PARATION DE LA DÃ‰MO ---" -ForegroundColor Cyan

# Nettoyage prÃ©ventif des rÃ©seaux (VBoxManage standard)
 = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
if (Test-Path ) {
    # On supprime aveuglÃ©ment les interfaces conflictuelles courantes
    # Redirection vers null pour ne pas polluer l'Ã©cran si l'interface n'existe pas
    &  hostonlyif remove "VirtualBox Host-Only Ethernet Adapter #3" 2>
    &  hostonlyif remove "VirtualBox Host-Only Ethernet Adapter #4" 2>
    &  hostonlyif remove "VirtualBox Host-Only Ethernet Adapter #5" 2>
    &  hostonlyif remove "VirtualBox Host-Only Ethernet Adapter #6" 2>
}

# 3. LANCEMENT
Write-Host "--- DÃ‰MARRAGE DES MACHINES ---" -ForegroundColor Green
vagrant up

if ( -eq 0) {
    Write-Host "
âœ… SYSTÃˆME OPÃ‰RATIONNEL" -ForegroundColor Green
    Write-Host "   -> Passerelle : 192.168.56.11"
    Write-Host "   -> Web        : 192.168.56.10"
    Write-Host "
PrÃªt pour la dÃ©monstration."
} else {
    Write-Host "
âŒ ERREUR CRITIQUE : Vagrant n'a pas dÃ©marrÃ©." -ForegroundColor Red
}

