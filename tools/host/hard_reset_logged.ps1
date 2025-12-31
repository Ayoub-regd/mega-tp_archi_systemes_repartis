# ==============================================================================
# SCRIPT : HARD RESET AVEC LOGS & FIX VMWARE
# EMPLACEMENT : /tools/hard_reset_logged.ps1
# AUTEUR : Ayoub (Version Finale)
# ==============================================================================

# 1. FIX CRITIQUE : CONTEXTE D'EXÉCUTION
# Force le script à s'exécuter depuis la racine du projet pour trouver le Vagrantfile
$ProjectRoot = Resolve-Path "$PSScriptRoot\.."
Set-Location $ProjectRoot

# 2. CONFIGURATION DES LOGS (Centralisés dans evidence/logs)
$LogDir = Join-Path $ProjectRoot "evidence\logs"
if (-not (Test-Path -Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$DateStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile = "$LogDir\reset_$DateStr.log"

# Fonction de logging (Écran + Fichier)
function Log-Message {
    param (
        [string]$Message,
        [string]$Color = "White"
    )
    $Timestamp = Get-Date -Format "HH:mm:ss"
    $FormattedMessage = "[$Timestamp] $Message"
    Write-Host $FormattedMessage -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $FormattedMessage
}

Clear-Host
Log-Message "=== DÉBUT DU HARD RESET DU LABO ===" "Cyan"
Log-Message "Racine du projet : $ProjectRoot" "Gray"
Log-Message "Logs : $LogFile" "Gray"
Log-Message "----------------------------------------" "Gray"

# 3. DESTRUCTION DE L'ENVIRONNEMENT
Log-Message "ÉTAPE 1/4 : Destruction des machines existantes..." "Yellow"
try {
    vagrant destroy -f 2>&1 | Out-File -FilePath $LogFile -Append -Encoding UTF8
    Log-Message "Machines détruites avec succès." "Green"
} catch {
    Log-Message "Erreur lors de la destruction (ou aucune machine active)." "Red"
}

# 4. FIX CONFLIT VMWARE (Le bloqueur d'IP)
Log-Message "ÉTAPE 2/4 : Vérification des conflits VMware..." "Yellow"
# On cherche l'adaptateur qui vole l'IP 192.168.56.1
$VmwareAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*VMware*" -and $_.Status -eq "Up" }

if ($VmwareAdapter) {
    foreach ($adapter in $VmwareAdapter) {
        Log-Message "   -> Conflit potentiel détecté : $($adapter.Name)" "Magenta"
        Log-Message "   -> Désactivation préventive..." "Magenta"
        try {
            Disable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop
            Log-Message "   -> Adaptateur VMware désactivé." "Green"
        } catch {
            Log-Message "   ⚠️ ÉCHEC : Impossible de désactiver VMware. LANCEZ EN ADMIN !" "Red"
        }
    }
} else {
    Log-Message "   -> Aucun conflit VMware détecté." "Gray"
}

# 5. NETTOYAGE RÉSEAU VIRTUALBOX
Log-Message "ÉTAPE 3/4 : Nettoyage des interfaces VirtualBox..." "Yellow"
$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

if (Test-Path $VBoxManage) {
    $interfaces = & $VBoxManage list hostonlyifs
    if ($interfaces) {
        $names = $interfaces | Select-String "Name:" | ForEach-Object { $_.ToString().Split(":")[1].Trim() }
        $cleaned = $false
        foreach ($name in $names) {
            # On supprime les interfaces Host-Only pour forcer la recréation propre
            if ($name -like "VirtualBox Host-Only*") {
                Log-Message "   -> Suppression de l'interface : $name" "Magenta"
                & $VBoxManage hostonlyif remove "$name" 2>&1 | Out-File -FilePath $LogFile -Append
                $cleaned = $true
            }
        }
        if (-not $cleaned) { Log-Message "   -> Aucune interface à nettoyer." "Gray" }
    } else {
        Log-Message "   -> Aucune interface Host-Only détectée." "Gray"
    }
} else {
    Log-Message "ERREUR CRITIQUE : VBoxManage introuvable." "Red"
}

# 6. RECONSTRUCTION TOTALE
Log-Message "ÉTAPE 4/4 : Reconstruction et Provisionning (Vagrant Up)..." "Yellow"
Log-Message "Cette étape peut prendre quelques minutes. Allez boire un café. ☕" "Cyan"

$timer = [System.Diagnostics.Stopwatch]::StartNew()

# Lancement de Vagrant (Redirection propre pour éviter le bug NativeCommandError)
vagrant up 2>&1 | Out-File -FilePath $LogFile -Append -Encoding UTF8

$timer.Stop()
$TimeElapsed = [math]::Round($timer.Elapsed.TotalMinutes, 2)

Log-Message "----------------------------------------" "Gray"
if ($LASTEXITCODE -eq 0) {
    Log-Message " SUCCÈS : Environnement prêt en $TimeElapsed minutes." "Green"
    Log-Message "   -> Passerelle : 192.168.56.11" "Green"
    Log-Message "   -> Web        : 192.168.56.10" "Green"
} else {
    Log-Message " ÉCHEC : Une erreur est survenue lors du 'vagrant up'." "Red"
    Log-Message "   -> Consultez le fichier log pour les détails." "Red"
}

Log-Message "=== FIN DU SCRIPT ===" "Cyan"