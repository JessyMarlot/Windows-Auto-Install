# ============================================================
# SCRIPT DE PRÉPARATION DE POSTE - UNIFIES
# ============================================================
# Ce script automatise la préparation complète d'un poste Windows.
# Ordre d'exécution :
#   1. Empêche la mise en veille pendant l'exécution
#   2. Vérifie les droits administrateur
#   3. Affiche un compte à rebours de 20 secondes
#   4. Détecte le fabricant et installe les pilotes constructeur
#   5. Installe les mises à jour Windows
#   6. Crée le compte administrateur local "admin"
#   7. Désactive le compte administrateur intégré par défaut
#   8. Supprime les scripts et la tâche planifiée
#   9. Génère un rapport final
#  10. Redémarre le système
# ============================================================

<#
.SYNOPSIS
    Script de préparation automatique de postes de travail Windows.

.DESCRIPTION
    Automatise plusieurs tâches de configuration d'un nouveau poste :
    - Installation des pilotes constructeur (HP, Dell, Lenovo)
    - Installation des mises à jour Windows
    - Création du compte administrateur local "admin"
    - Désactivation du compte administrateur intégré

.NOTES
    Auteur  : Jessy Marlot
    Version : CONSOLIDÉE (scripts HP, Dell, Lenovo intégrés)
    Droits  : Nécessite des droits administrateur
    Lancement : Automatique après un compte à rebours de 20 secondes
#>


# ------------------------------------------------------------
# CLASSE C# : PowerManagement
# ------------------------------------------------------------
# Expose l'API Windows SetThreadExecutionState via P/Invoke.
# Permet de contrôler la mise en veille du système pendant
# l'exécution du script (critique pour les longues opérations).

param (
    [string]$cible
)
$script:cible = $cible


Add-Type @'
using System;
using System.Runtime.InteropServices;

public class PowerManagement
{
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;
}
'@

function Argument {   
    try {
        $JsonPath = "C:\script\config.json"
        $Config = (Get-Content -Path $JsonPath -Raw | ConvertFrom-Json).$cible
        $Annee = (Get-Date).Year
        $script:PasswordParam = $Config.replace('{year}', $Annee)
        Write-Log -Message "Le mot de passe de $cible a été récupéré avec succès"  -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Le fichier config.json est introuvable à l'emplacement $JsonPath"  -Level "ERROR"
        Write-Log -Message "Le mot de passe par défaut sera utilisé"  -Level "INFO"
        $script:PasswordParam = "admin"
    }
}

# ------------------------------------------------------------
# FONCTION : PreventSleep
# ------------------------------------------------------------
# Empêche le système de se mettre en veille pendant l'exécution du script.
# Flags utilisés :
#   ES_CONTINUOUS       : maintient l'état demandé jusqu'à nouvel ordre
#   ES_SYSTEM_REQUIRED  : empêche la mise en veille du système
#   ES_DISPLAY_REQUIRED : empêche l'extinction de l'écran
Function PreventSleep {
    $result = [PowerManagement]::SetThreadExecutionState(
        [PowerManagement]::ES_CONTINUOUS -bor 
        [PowerManagement]::ES_SYSTEM_REQUIRED -bor 
        [PowerManagement]::ES_DISPLAY_REQUIRED
    )
    
    if ($result -ne 0) {
        Write-Host "Protection contre la mise en veille activée" -ForegroundColor Green
    }
}


# ------------------------------------------------------------
# FONCTION : Restore-SleepSettings
# ------------------------------------------------------------
# Restaure le comportement normal de mise en veille du système.
# Appelée à la fin du script (bloc finally) pour rendre le contrôle au système.
Function Restore-SleepSettings {
    $result = [PowerManagement]::SetThreadExecutionState([PowerManagement]::ES_CONTINUOUS)
    
    if ($result -ne 0) {
        Write-Host "Comportement normal de mise en veille restauré" -ForegroundColor Green
    }
}


# ------------------------------------------------------------
# VÉRIFICATION DES DROITS ADMINISTRATEUR
# ------------------------------------------------------------
# Le script ne peut pas s'exécuter sans droits élevés.
# En cas d'absence de droits, affiche un message d'erreur et quitte.
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERREUR : Ce script nécessite des droits administrateur !" -ForegroundColor Red
    Write-Host "Veuillez relancer PowerShell en tant qu'administrateur." -ForegroundColor Yellow
    pause
    exit
}

# Encodage UTF-8 pour l'affichage correct des caractères accentués
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Activation immédiate de la protection anti-veille
PreventSleep


# ------------------------------------------------------------
# VARIABLES GLOBALES
# ------------------------------------------------------------
# Horodatage de démarrage du script (utilisé dans le rapport final)
$script:ScriptStartTime = Get-Date

# Statistiques collectées pendant l'exécution (affichées dans le rapport final)
$script:Stats = @{
    MajesWindowsInstallees   = 0
    PilotesInstalles         = $false
}
$script:InternetDisponible = $true

# Fichier JSON de checkpoint pour sauvegarder la progression (reprise après redémarrage)
$script:CheckpointFile = "C:\Logs\ScriptCheckpoint.json"


# ============================================================
# FONCTIONS DE LOGGING ET DE CHECKPOINT
# ============================================================


# ------------------------------------------------------------
# FONCTION : Write-Log
# ------------------------------------------------------------
# Fonction de logging centralisée. Écrit chaque message dans un fichier
# de log horodaté et l'affiche dans la console avec une couleur selon le niveau.
# Niveaux disponibles : INFO (Cyan), SUCCESS (Vert), WARNING (Jaune), ERROR (Rouge)
Function Write-Log {
    <#
    .SYNOPSIS
        Fonction centralisée pour écrire des logs dans un fichier et afficher dans la console.

    .PARAMETER Message
        Le message à logger.

    .PARAMETER Level
        Le niveau de log : INFO, SUCCESS, WARNING, ERROR.

    .PARAMETER LogFile
        Le chemin du fichier de log (par défaut C:\Logs\ScriptPreparationPoste.log).
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO",
        
        [Parameter(Mandatory=$false)]
        [string]$LogFile = "C:\Logs\ScriptPreparationPoste.log"
    )
    
    # Créer le répertoire de logs s'il n'existe pas
    $logDir = Split-Path -Path $LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    # Formater le message avec horodatage
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Écrire dans le fichier de log
    Add-Content -Path $LogFile -Value $logMessage
    
    # Afficher dans la console avec la couleur correspondant au niveau
    switch ($Level) {
        "INFO"    { Write-Host $Message -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $Message -ForegroundColor Green }
        "WARNING" { Write-Host $Message -ForegroundColor Yellow }
        "ERROR"   { Write-Host $Message -ForegroundColor Red }
    }
}


# ============================================================
# FONCTIONS DE GESTION DU CHECKPOINT
# ============================================================
# Le système de checkpoint sauvegarde la progression du script dans un fichier
# JSON afin de permettre une reprise automatique après un redémarrage ou
# une interruption. Chaque étape complétée est enregistrée par son nom.
# Ce script étend le checkpoint du lanceur avec un champ supplémentaire : Fabricant.


# ------------------------------------------------------------
# FONCTION : Initialize-Checkpoint
# ------------------------------------------------------------
# Crée le fichier de checkpoint s'il n'existe pas encore.
# Structure JSON : CurrentStep, StepsCompleted, StartTime, LastUpdate, Fabricant
Function Initialize-Checkpoint {
    $checkpointDir = Split-Path -Path $script:CheckpointFile -Parent
    if (-not (Test-Path $checkpointDir)) {
        New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null
    }
    if (-not (Test-Path $script:CheckpointFile)) {
        $initialCheckpoint = @{
            CurrentStep    = 0
            StepsCompleted = @()
            StartTime      = (Get-Date).ToString("o")
            LastUpdate     = (Get-Date).ToString("o")
            Fabricant      = ""
            Cible          = ""
        }
        $initialCheckpoint | ConvertTo-Json | Set-Content $script:CheckpointFile
    }
}


# ------------------------------------------------------------
# FONCTION : Get-CheckpointState
# ------------------------------------------------------------
# Lit et retourne l'état actuel du checkpoint depuis le fichier JSON.
# En cas de fichier corrompu, le réinitialise et retourne un état vierge.
# Retourne $null si le fichier n'existe pas.
Function Get-CheckpointState {
    if (Test-Path $script:CheckpointFile) {
        try {
            $checkpoint = Get-Content $script:CheckpointFile -Raw | ConvertFrom-Json
            return $checkpoint
        } catch {
            # Fichier corrompu : suppression et réinitialisation
            Remove-Item $script:CheckpointFile -Force -ErrorAction SilentlyContinue
            Initialize-Checkpoint
            return Get-Content $script:CheckpointFile -Raw | ConvertFrom-Json
        }
    }
    return $null
}


# ------------------------------------------------------------
# FONCTION : Save-CheckpointStep
# ------------------------------------------------------------
# Enregistre la complétion d'une étape dans le fichier de checkpoint.
# Met à jour le numéro d'étape courant, la liste des étapes terminées,
# et optionnellement le fabricant détecté.
Function Save-CheckpointStep {
    param(
        [Parameter(Mandatory=$true)]
        [int]$StepNumber,
        [Parameter(Mandatory=$true)]
        [string]$StepName,
        [Parameter(Mandatory=$false)]
        [string]$Fabricant = "",
        [Parameter(Mandatory=$false)]
        [string]$Cible = ""
    )
    try {
        $checkpoint = Get-CheckpointState
        if (-not $checkpoint) {
            # Initialisation si le checkpoint n'existe pas encore
            Initialize-Checkpoint
            $checkpoint = Get-CheckpointState
        }
        $checkpoint.CurrentStep = $StepNumber
        if ($checkpoint.StepsCompleted -notcontains $StepName) {
            $checkpoint.StepsCompleted += $StepName
        }
        $checkpoint.LastUpdate = (Get-Date).ToString("o")
        if ($Fabricant) {
            $checkpoint.Fabricant = $Fabricant
        }
        if ($Cible) {
            $checkpoint.Cible = $Cible
        }
        $checkpoint | ConvertTo-Json | Set-Content $script:CheckpointFile -Force
        Write-Log -Message "Checkpoint sauvegarde : Etape $StepNumber ($StepName) terminee" -Level "SUCCESS"
    } catch {
        Write-Log -Message "Erreur lors de la sauvegarde du checkpoint : $($_.Exception.Message)" -Level "ERROR"
    }
}


# ------------------------------------------------------------
# FONCTION : Test-StepCompleted
# ------------------------------------------------------------
# Retourne $true si l'étape donnée figure déjà dans le checkpoint.
# Utilisé pour éviter de rejouer une étape déjà complétée.
Function Test-StepCompleted {
    param(
        [Parameter(Mandatory=$true)]
        [string]$StepName
    )
    $checkpoint = Get-CheckpointState
    if ($checkpoint -and $checkpoint.StepsCompleted -contains $StepName) {
        return $true
    }
    return $false
}


# ------------------------------------------------------------
# FONCTION : Clear-Checkpoint
# ------------------------------------------------------------
# Supprime le fichier de checkpoint une fois toutes les étapes terminées.
Function Clear-Checkpoint {
    if (Test-Path $script:CheckpointFile) {
        Remove-Item $script:CheckpointFile -Force
        Write-Log -Message "Checkpoint supprime - script termine avec succes" -Level "SUCCESS"
    }
}


# ============================================================
# FONCTIONS MÉTIER
# ============================================================


# ------------------------------------------------------------
# FONCTION : Write-SystemInfo
# ------------------------------------------------------------
# Collecte et logue les informations matérielles et logicielles du poste :
# nom, fabricant, modèle, OS, architecture, RAM et CPU.
Function Write-SystemInfo {
    <#
    .SYNOPSIS
        Logue les informations système importantes.

    .DESCRIPTION
        Enregistre les détails du système (OS, RAM, CPU, fabricant) dans le fichier de log.
    #>
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "INFORMATIONS SYSTÈME" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    
    try {
        $os  = Get-CimInstance -ClassName Win32_OperatingSystem
        $cs  = Get-CimInstance -ClassName Win32_ComputerSystem
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        
        Write-Log -Message "Nom du PC : $($cs.Name)" -Level "INFO"
        Write-Log -Message "Fabricant : $($cs.Manufacturer)" -Level "INFO"
        Write-Log -Message "Modèle : $($cs.Model)" -Level "INFO"
        Write-Log -Message "OS : $($os.Caption) $($os.Version)" -Level "INFO"
        Write-Log -Message "Architecture : $($os.OSArchitecture)" -Level "INFO"
        Write-Log -Message "RAM : $([math]::Round($cs.TotalPhysicalMemory / 1GB, 2)) GB" -Level "INFO"
        Write-Log -Message "CPU : $($cpu.Name)" -Level "INFO"
        Write-Log -Message "Coeurs CPU : $($cpu.NumberOfCores)" -Level "INFO"
        
    } catch {
        Write-Log -Message "Erreur lors de la récupération des informations système : $($_.Exception.Message)" -Level "ERROR"
    }
    
    Write-Log -Message "========================================" -Level "INFO"
}


# ------------------------------------------------------------
# FONCTION : CreadminBV
# ------------------------------------------------------------
# Crée le compte administrateur local "admin" s'il n'existe pas encore.
# Le compte est ajouté au groupe Administrateurs via son SID (indépendant de la langue).
Function CreadminBV {
    <#
    .SYNOPSIS
        Crée le compte administrateur local "admin".

    .DESCRIPTION
        Vérifie si le compte existe déjà.
        Si non, crée le compte avec un mot de passe fixe et l'ajoute au groupe Administrateurs.
    #>
    
    Write-Log -Message "Début de la création du compte administrateur Admin" -Level "INFO"
    
    # Vérification de l'existence préalable du compte
    $user = Get-LocalUser | Where-Object {$_.Name -eq "admin"}
    
    if ($user) {
        Write-Log -Message "L'utilisateur 'admin' existe déjà !" -Level "WARNING"
        Write-Host
    } else {
        try {
            $passwordTemp = $script:PasswordParam
            $password = ConvertTo-SecureString $passwordTemp -AsPlainText -Force
            
            # Création du compte utilisateur avec mot de passe permanent
            New-LocalUser -Name "admin" -Password $password -AccountNeverExpires -FullName "admin" -Description "Compte administrateur local du poste"
            Write-Log -Message "L'utilisateur 'admin' a été créé avec succès." -Level "SUCCESS"

            # Ajout au groupe Administrateurs via SID S-1-5-32-544 (indépendant de la langue du système)
            Add-LocalGroupMember -SID "S-1-5-32-544" -Member "admin"
            Write-Log -Message "L'utilisateur 'admin' a été ajouté au groupe Administrateurs." -Level "SUCCESS"
        }
        catch {
            Write-Log -Message "Erreur lors de la création du compte : $($_.Exception.Message)" -Level "ERROR"
        }
    }
    return
}


# ------------------------------------------------------------
# FONCTION : DesactiverAdminLocal
# ------------------------------------------------------------
# Désactive le compte administrateur intégré de Windows (RID 500).
# Utilise le SID (S-1-5-21-*-500) pour être indépendant de la langue du système.
Function DesactiverAdminLocal {
    <#
    .SYNOPSIS
        Désactive le compte administrateur local par défaut.

    .DESCRIPTION
        Identifie le compte administrateur intégré via son RID (500)
        et le désactive pour des raisons de sécurité.
    #>
    
    Write-Log -Message "Début de la désactivation du compte administrateur local" -Level "INFO"
    
    try {
        # Récupération du compte administrateur intégré par son RID 500
        $adminAccount = Get-LocalUser | Where-Object { $_.SID -like "*-500" }
        
        if ($adminAccount) {
            Disable-LocalUser -SID $adminAccount.SID
            Write-Log -Message "L'utilisateur '$($adminAccount.Name)' a été désactivé avec succès." -Level "SUCCESS"
        } else {
            Write-Log -Message "Le compte administrateur local n'a pas été trouvé." -Level "WARNING"
        }
    } catch {
        Write-Log -Message "Erreur lors de la désactivation du compte administrateur : $($_.Exception.Message)" -Level "ERROR"
    }
    return
}


# ------------------------------------------------------------
# FONCTION : Install-HPDrivers
# ------------------------------------------------------------
# Installe les pilotes, BIOS et firmware HP via le module HPCMSL.
# Télécharge l'ensemble des SoftPaqs recommandés pour le modèle détecté
# et les installe silencieusement dans un dossier temporaire.
function Install-HPDrivers {
    <#
    .SYNOPSIS
        Installe les pilotes HP via le module HPCMSL.

    .DESCRIPTION
        - Force TLS 1.2 pour les téléchargements depuis PowerShell Gallery
        - Installe le module HPCMSL
        - Récupère et installe les SoftPaqs (drivers, BIOS, firmware) pour ce modèle HP
    #>
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "INSTALLATION DES PILOTES HP" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    
    # Forcer TLS 1.2 pour les téléchargements depuis PowerShell Gallery
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    Write-Log -Message "Configuration des outils de gestion de paquets" -Level "INFO"
    
    try {
        Import-module PackageManagement
        Update-Module
        Import-Module PowerShellGet
        
        Write-Log -Message "Installation du module HPCMSL..." -Level "INFO"
        try {
            Install-Module -Name HPCMSL -Force -Confirm:$false -Scope AllUsers -AcceptLicense
        }
        catch {
            Install-Module -Name HPCMSL -Force -Confirm:$false -Scope AllUsers
        }
        Write-Log -Message "Début de la mise à jour des pilotes et firmware HP" -Level "INFO"
        
        # Chargement du module HPCMSL (arrêt si échec)
        Import-Module HPCMSL -ErrorAction Stop
        
        # Dossier temporaire de téléchargement des SoftPaqs
        $TempDir = "C:\Windows\Temp\HPSoftPaqs"
        if (!(Test-Path $TempDir)) { 
            New-Item -ItemType Directory -Path $TempDir | Out-Null
        }
        $env:HP_SOFTPAQ_DESTINATION = $TempDir

        # Récupération de la liste des SoftPaqs recommandés (Drivers, BIOS et Firmware)
        Write-Log -Message "Récupération de la liste des SoftPaqs disponibles..." -Level "INFO"
        $SoftPaqList = Get-HPSoftPaqList -Category Driver,BIOS,Firmware
            
        Write-Log -Message "$($SoftPaqList.Count) SoftPaq(s) trouvé(s)" -Level "INFO"
            
        foreach ($SoftPaq in $SoftPaqList) {
            Try {
                Write-Log -Message "Installation de : $($SoftPaq.Id) ($($SoftPaq.Name))" -Level "INFO"
                    
                # Téléchargement et installation silencieuse
                Get-HPSoftPaq -Number $SoftPaq.Id -Action SilentInstall -DestinationPath $TempDir
                    
                Write-Log -Message "SoftPaq $($SoftPaq.Id) installé avec succès" -Level "SUCCESS"
            }
            catch {
                Write-Log -Message "Échec ou non disponible : $($SoftPaq.Id) - $($_.Exception.Message)" -Level "WARNING"
            }
        }
            
        $script:Stats.PilotesInstalles = $true
        
        # Nettoyage des exécutables temporaires
        Write-Log -Message "Nettoyage des fichiers temporaires..." -Level "INFO"
        Remove-Item -Path "$TempDir\*" -Include *.exe -Force -ErrorAction SilentlyContinue
        
        Write-Log -Message "Installation des pilotes HP terminée" -Level "SUCCESS"
        
    } catch {
        Write-Log -Message "Erreur lors de l'installation des pilotes HP : $($_.Exception.Message)" -Level "ERROR"
    }
    
    Write-Log -Message "========================================" -Level "INFO"
}


# ------------------------------------------------------------
# FONCTION : Install-DellDrivers
# ------------------------------------------------------------
# Installe les pilotes, BIOS, firmware et applications Dell via Dell Command Update (DCU).
# Interroge le catalogue CAB Dell pour obtenir dynamiquement la dernière version de DCU.
# Télécharge et installe DCU si absent ou obsolète, puis lance les scans et installations
# par catégorie. Un fallback vers une URL connue est prévu si le catalogue est inaccessible.
function Install-DellDrivers {
    <#
    .SYNOPSIS
        Installe les pilotes Dell via Dell Command Update.

    .DESCRIPTION
        - Interroge le catalogue CAB Dell (CatalogPC.cab) pour résoudre dynamiquement
          l'URL et la version de la dernière version de Dell Command Update (WIN64)
        - Fallback vers une URL en dur si le catalogue est inaccessible
        - Télécharge et installe Dell Command Update en mode silencieux si absent ou obsolète
        - Lance les mises à jour par catégorie : BIOS, firmware, drivers, applications
        - Le redémarrage automatique est désactivé (géré par le script principal)
    #>
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "INSTALLATION DES PILOTES DELL" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    
try {
    # ── Étape 1 : Activation du bypass certificat pour le Microsoft Store ─────────
    Write-Log -Message "Activation du bypass de certificat pour le Microsoft Store..." -Level "INFO"
    try {
        winget settings --enable BypassCertificatePinningForMicrosoftStore
        Write-Log -Message "Bypass certificat activé avec succès." -Level "INFO"
    } catch {
        Write-Log -Message "Avertissement : Impossible d'activer le bypass certificat : $($_.Exception.Message)" -Level "WARNING"
    }

    # ── Étape 2 : Installation de Dell Command Update via winget ──────────────────
    Write-Log -Message "Installation de Dell Command Update via winget..." -Level "INFO"
    $wingetResult = Start-Process -FilePath "winget" `
                                  -ArgumentList "install Dell.CommandUpdate --accept-source-agreements --silent" `
                                  -Wait -NoNewWindow -PassThru

    Write-Log -Message "Dell Command Update installé avec succès (code : $($wingetResult.ExitCode))." -Level "SUCCESS"

    # ── Étape 3 : Désactivation du bypass certificat ──────────────────────────────
    Write-Log -Message "Désactivation du bypass de certificat..." -Level "INFO"
    try {
        winget settings --disable BypassCertificatePinningForMicrosoftStore
        Write-Log -Message "Bypass certificat désactivé avec succès." -Level "INFO"
    } catch {
        Write-Log -Message "Avertissement : Impossible de désactiver le bypass certificat : $($_.Exception.Message)" -Level "WARNING"
    }

    # ── Étape 4 : Vérification de la présence de dcu-cli.exe ─────────────────────
    $DCU = "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
    Write-Log -Message "Vérification de la présence de dcu-cli.exe : $DCU" -Level "INFO"

    if (-not (Test-Path $DCU)) {
        throw "dcu-cli.exe introuvable après installation : $DCU"
    }
    Write-Log -Message "dcu-cli.exe détecté avec succès." -Level "INFO"

    # ── Étape 5 : Scan des mises à jour disponibles ───────────────────────────────
    Write-Log -Message "Lancement du scan des mises à jour Dell..." -Level "INFO"
    $scanResult = Start-Process -FilePath $DCU `
                                -ArgumentList "/scan" `
                                -Wait -NoNewWindow -PassThru

    Write-Log -Message "Scan terminé (code : $($scanResult.ExitCode))." -Level "INFO"

    # ── Étape 6 : Application des mises à jour ────────────────────────────────────
    Write-Log -Message "Application des mises à jour Dell (forceUpdate activé)..." -Level "INFO"
    Write-Host "Certaines mises à jour peuvent paraître bloquée, il y a besoin d'appuyer sur entrée pour continuer" -ForegroundColor White -BackgroundColor Red
    $updateResult = Start-Process -FilePath $DCU `
                                  -ArgumentList "/applyUpdates -forceUpdate=enable" `
                                  -Wait -NoNewWindow -PassThru

    if ($updateResult.ExitCode -ne 0) {
        Write-Log -Message "Avertissement : applyUpdates a retourné le code $($updateResult.ExitCode). Certaines mises à jour peuvent nécessiter un redémarrage." -Level "WARNING"
    } else {
        Write-Log -Message "Mises à jour Dell appliquées avec succès." -Level "SUCCESS"
    }

    Write-Log -Message "Installation des pilotes Dell terminée." -Level "SUCCESS"
    $script:Stats.PilotesInstalles = $true

} catch {
    Write-Log -Message "Erreur lors de l'installation des pilotes Dell : $($_.Exception.Message)" -Level "ERROR"
} finally {
    Write-Log -Message "========================================" -Level "INFO"
}
}




# ------------------------------------------------------------
# FONCTION : Install-LenovoDrivers
# ------------------------------------------------------------
# Installe les mises à jour Lenovo via le module LSUClient.
# Filtre les mises à jour compatibles avec une installation sans surveillance
# et les installe séquentiellement.
function Install-LenovoDrivers {
    <#
    .SYNOPSIS
        Installe les pilotes Lenovo via le module LSUClient.

    .DESCRIPTION
        - Installe le module LSUClient depuis PowerShell Gallery
        - Récupère les mises à jour disponibles compatibles avec l'installation automatique
        - Télécharge puis installe les mises à jour filtrées
    #>
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "INSTALLATION DES PILOTES LENOVO" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    
    try {
        Import-module PackageManagement
        Update-Module
        Import-Module PowerShellGet

        Write-Log -Message "Installation du module LSUClient..." -Level "INFO"
        Install-Module -Name LSUClient -Force -Scope AllUsers -Confirm:$false
        
        Write-Log -Message "Module LSUClient installé avec succès" -Level "SUCCESS"
        
        # Récupération des mises à jour supportant l'installation sans surveillance
        Write-Log -Message "Récupération de la liste des mises à jour Lenovo..." -Level "INFO"
        $updates = Get-LSUpdate | Where-Object { $_.Installer.Unattended }
        
        if ($updates) {
            Write-Log -Message "$($updates.Count) mise(s) à jour trouvée(s)" -Level "INFO"
            
            Write-Log -Message "Téléchargement des mises à jour..." -Level "INFO"
            $updates | Save-LSUpdate -Verbose
            
            Write-Log -Message "Installation des mises à jour..." -Level "INFO"
            $updates | Install-LSUpdate -Verbose
            
            Write-Log -Message "Installation des pilotes Lenovo terminée" -Level "SUCCESS"
            $script:Stats.PilotesInstalles = $true
        } else {
            Write-Log -Message "Aucune mise à jour Lenovo disponible" -Level "INFO"
        }
        
    } catch {
        Write-Log -Message "Erreur lors de l'installation des pilotes Lenovo : $($_.Exception.Message)" -Level "ERROR"
    }
    
    Write-Log -Message "========================================" -Level "INFO"
}


# ------------------------------------------------------------
# FONCTION : GestionFabricant
# ------------------------------------------------------------
# Aiguille vers la fonction d'installation de pilotes adaptée au fabricant détecté.
# Fabricants pris en charge : HP, Dell, Lenovo.
# Tout autre fabricant est signalé en erreur sans interruption du script.
function GestionFabricant {
    <#
    .SYNOPSIS
        Orchestre l'installation des pilotes constructeur selon le fabricant détecté.

    .PARAMETER fabricant
        Le nom du fabricant normalisé (hp, dell, lenovo).
    #>
    
    param(
        [string]$fabricant
    )

    Write-Log -Message "Début de la gestion pour le fabricant : $fabricant" -Level "INFO"

    if (-not (Test-InternetConnection)) {
    Write-Log -Message "Aucune connexion internet détectée" -Level "WARNING"
    Write-Log -Message "Les mises à jour Windows ne peuvent pas être téléchargées" -Level "WARNING"
    Write-Log -Message "Connectez le poste à Internet et redémarrez le pour que l'installation continue" -Level "WARNING"
    $script:InternetDisponible = $false
    return
    }

    switch ($fabricant.ToLower()) {
        "hp"     { Install-HPDrivers;     return }
        "dell"   { Install-DellDrivers;   return }
        "lenovo" { Install-LenovoDrivers; return }
        default  { Write-Log -Message "Fabricant non pris en charge : $fabricant" -Level "ERROR" }
    }
}


# ------------------------------------------------------------
# FONCTION : MajWindows
# ------------------------------------------------------------
# Installe toutes les mises à jour Windows disponibles via le module PSWindowsUpdate.
# Installe PSWindowsUpdate si absent, vérifie la connexion internet au préalable,
# puis lance le téléchargement et l'installation sans redémarrage automatique.
function MajWindows {
    <#
    .SYNOPSIS
        Recherche et installe toutes les mises à jour Windows disponibles.

    .DESCRIPTION
        - Vérifie la connexion internet (quitte si absente)
        - Installe le module PSWindowsUpdate si nécessaire
        - Lance l'installation des mises à jour sans redémarrage automatique
        - Enregistre le nombre de mises à jour installées dans les statistiques

    .NOTES
        Nécessite le module PSWindowsUpdate (installé automatiquement si absent).
    #>
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "MISES À JOUR WINDOWS" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    
    Write-Log -Message "Vérification du module PSWindowsUpdate" -Level "INFO"

    # Vérification de la connectivité internet avant tout téléchargement
    if (-not (Test-InternetConnection)) {
        Write-Log -Message "Aucune connexion internet détectée" -Level "WARNING"
        Write-Log -Message "Les mises à jour Windows ne peuvent pas être téléchargées" -Level "WARNING"
        Write-Log -Message "Connectez le poste à Internet et redémarrez le pour que l'installation continue" -Level "WARNING"
        $script:InternetDisponible = $false
        return
    }
    
    # Installation de PSWindowsUpdate si le module est absent
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Log -Message "Installation du module PSWindowsUpdate..." -Level "INFO"
        try {
            Install-Module PSWindowsUpdate -Force -SkipPublisherCheck
            Write-Log -Message "Module PSWindowsUpdate installé avec succès" -Level "SUCCESS"
        } catch {
            Write-Log -Message "Erreur lors de l'installation du module PSWindowsUpdate : $($_.Exception.Message)" -Level "ERROR"
            return
        }
    }
    
    # Chargement des modules nécessaires
    Write-Log -Message "Installation de powershell PackageManagement..." -Level "INFO"
    Import-Module PackageManagement
    Write-Log -Message "Installation de PSWindowsUpdate..." -Level "INFO"
    Import-Module PSWindowsUpdate
    
    Write-Log -Message "Recherche et installation des mises à jour Windows..." -Level "INFO"
    Write-Host "Certaines mises à jour sont très lentes et peuvent paraître bloquée, si appuyer sur la touche entrée ne fait rien alors la mise à jour est toujours en cours" -ForegroundColor White -BackgroundColor Red
    Write-Host "Heure de commencement de maj windows: $(Get-Date -Format 'HH:mm')" -ForegroundColor White -BackgroundColor Red
    $updateStart = Get-Date
    
    try {
        # Lancement de l'installation des mises à jour :
        # -MicrosoftUpdate  : inclut les mises à jour Microsoft (pas seulement Windows)
        # -AcceptAll        : accepte toutes les mises à jour sans confirmation
        # -ForceDownload    : force le téléchargement même si déjà en cache
        # -ForceInstall     : force l'installation même si déjà proposée
        # -IgnoreReboot     : ne redémarre pas automatiquement (le script gère le redémarrage)
        $updateResults = Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -ForceDownload -ForceInstall -IgnoreReboot -Confirm:$false

        # Mise à jour des statistiques
        if ($updateResults) {
            $script:Stats.MajesWindowsInstallees = $updateResults.Count
            Write-Log -Message "$($updateResults.Count) mise(s) à jour Windows installée(s)" -Level "SUCCESS"
        }
        $updateDuration = (Get-Date) - $updateStart
        Write-Log -Message "Mises à jour Windows terminées en $([math]::Round($updateDuration.TotalMinutes, 2)) minutes" -Level "SUCCESS"

    } catch {
        Write-Log -Message "Erreur lors de l'installation des mises à jour Windows : $($_.Exception.Message)" -Level "ERROR"
    }
    
    Write-Log -Message "========================================" -Level "INFO"
}


# ------------------------------------------------------------
# FONCTION : GenerateFinalReport
# ------------------------------------------------------------
# Génère et logue un rapport de fin d'exécution contenant :
# l'heure de début, l'heure de fin, la durée totale et les statistiques
# (mises à jour installées, pilotes, logiciels échoués).
Function GenerateFinalReport {
    <#
    .SYNOPSIS
        Génère un rapport final complet de l'exécution du script.

    .DESCRIPTION
        Affiche et enregistre dans le log :
        - Les horodatages de début et de fin
        - La durée totale d'exécution
        - Les statistiques : mises à jour, pilotes, logiciels échoués
    #>
    
    $scriptEndTime  = Get-Date
    $totalDuration  = $scriptEndTime - $script:ScriptStartTime
    
    Write-Host ""
    Write-Host ""
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "RAPPORT FINAL D'EXÉCUTION" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    # Horodatages
    Write-Log -Message "Heure de début : $($script:ScriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -Level "INFO"
    Write-Log -Message "Heure de fin : $($scriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))" -Level "INFO"
    Write-Log -Message "Durée totale : $([math]::Round($totalDuration.TotalMinutes, 2)) minutes ($([math]::Round($totalDuration.TotalHours, 2)) heures)" -Level "INFO"
    Write-Host ""
    
    # Statistiques d'exécution
    Write-Log -Message "STATISTIQUES :" -Level "INFO"
    Write-Log -Message "Mises à jour Windows installées : $($script:Stats.MajesWindowsInstallees)" -Level "INFO"
    Write-Log -Message "Pilotes constructeur installés : $(if ($script:Stats.PilotesInstalles) { 'Oui' } else { 'Non' })" -Level "INFO"
    Write-Host ""
    
    Write-Host ""
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "SCRIPT TERMINÉ" -Level "SUCCESS"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    Write-Host "Les logs complets sont disponibles dans : C:\Logs\ScriptPreparationPoste.log" -ForegroundColor Cyan
    Write-Host ""
}


# ------------------------------------------------------------
# FONCTION : Get-NormalizedManufacturer
# ------------------------------------------------------------
# Lit le fabricant brut depuis WMI et le normalise en une valeur simple
# (hp, dell ou lenovo) pour être utilisée par GestionFabricant.
Function Get-NormalizedManufacturer {
    <#
    .SYNOPSIS
        Détecte et normalise le nom du fabricant du PC.
    #>
    $fabricantBrut = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
    $fabricant = switch -Regex ($fabricantBrut.ToLower()) {
        "hp|hewlett" { "hp" }
        "dell"       { "dell" }
        "lenovo"     { "lenovo" }
        default      { $fabricantBrut }
    }
    
    Write-Log -Message "Fabricant brut détecté : $fabricantBrut" -Level "INFO"
    Write-Log -Message "Fabricant normalisé : $fabricant" -Level "INFO"
    
    return $fabricant
}


# ------------------------------------------------------------
# FONCTION : Test-InternetConnection
# ------------------------------------------------------------
# Teste la connectivité internet via un ping vers 8.8.8.8 (Google DNS).
# Retourne $true si la connexion est disponible, $false sinon.
# Utilisée avant tout téléchargement de modules ou de mises à jour.
Function Test-InternetConnection {
    <#
    .SYNOPSIS
        Teste la connexion internet.

    .OUTPUTS
        Boolean - $true si la connexion internet est disponible, $false sinon.
    #>
    
    try {
        # Ping vers Google DNS (8.8.8.8) — 2 tentatives
        $pingResult = Test-Connection -ComputerName "8.8.8.8" -Count 2 -Quiet -ErrorAction Stop
        
        if ($pingResult) {
            Write-Log -Message "Connexion internet détectée" -Level "INFO"
            return $true
        } else {
            Write-Log -Message "Aucune connexion internet détectée" -Level "WARNING"
            return $false
        }
    } catch {
        Write-Log -Message "Impossible de tester la connexion internet : $($_.Exception.Message)" -Level "WARNING"
        return $false
    }
}


# ------------------------------------------------------------
# FONCTION : Wait-ForTimeout
# ------------------------------------------------------------
# Affiche un compte à rebours de 20 secondes avant le démarrage automatique du script.
# Informe l'utilisateur du fabricant détecté, des actions qui vont être effectuées
# et du mot de passe du compte admin qui sera créé.
function Wait-ForTimeout {
    <#
    .SYNOPSIS
        Affiche un compte à rebours avant le démarrage automatique du script.

    .DESCRIPTION
        Affiche les informations importantes à l'utilisateur :
        - Le fabricant détecté
        - Le mot de passe du compte admin qui sera créé
        - La liste des actions prévues
        Un compte à rebours de 20 secondes s'écoule avant le lancement.

    .PARAMETER Timeout
        Durée du compte à rebours en secondes (par défaut 20).
    #>
    
    param ( [int]$Timeout = 20 )
    
    Write-Log -Message "Démarrage du compte à rebours ($Timeout secondes)" -Level "INFO"
    
    # Mot de passe affiché à l'utilisateur (identique à celui utilisé dans CreadminBV)
    $passwordShow = $script:PasswordParam
    
    # Détection du fabricant pour affichage et transmission à ScriptAuto
    $fabricant = Get-NormalizedManufacturer
    
    # Boucle de compte à rebours : affichage mis à jour chaque seconde
    for ($i = $Timeout; $i -ge 0; $i--) {
        Clear-Host
        Write-Host "Fabricant détecté : $fabricant" -ForegroundColor Cyan
        Write-Host "Un compte admin" -NoNewline
        Write-Host -ForegroundColor White " Admin " -NoNewline
        Write-Host "avec le mot de passe" -NoNewline
        Write-Host -ForegroundColor White " $passwordShow " -NoNewline
        Write-Host "va être créé."
        Write-Host "Le compte administrateur par défaut va être désactivé."
        Write-Host "Les mises à jour Windows vont être installées."
        Write-Host "Le lancement de script sera interdit sur le poste."
        Write-Host "Le script sera supprimé au prochain redémarrage."
        Write-Host "Les logs seront disponible à C:\Logs." -ForegroundColor Cyan
        Write-host "Début du script dans $i secondes" 
        Start-Sleep -Seconds 1
    }

    # Compte à rebours écoulé : lancement du script
    Write-Log -Message "Compte à rebours terminé, lancement du script automatique" -Level "INFO"
    
    # Transmission du fabricant détecté à la fonction principale
    ScriptAuto -fabricant $fabricant -cible $script:cible
}


# ------------------------------------------------------------
# FONCTION : ScriptAuto
# ------------------------------------------------------------
# Fonction principale qui orchestre toutes les étapes dans l'ordre.
# Gère la reprise après interruption via le système de checkpoint.
# Un bloc finally garantit la restauration de la mise en veille en toutes circonstances.
function ScriptAuto {
    <#
    .SYNOPSIS
        Fonction principale qui orchestre toutes les étapes du script.

    .DESCRIPTION
        Exécute dans l'ordre :
        0. Log des informations système
        1. Installation des pilotes constructeur
        2. Installation des mises à jour Windows
        3. Création du compte admin admin
        4. Désactivation du compte administrateur intégré
        5. Suppression des scripts et de la tâche planifiée
        6. Génération du rapport final
        7. Suppression du checkpoint
        8. Redémarrage du système

    .PARAMETER fabricant
        Le nom du fabricant normalisé, transmis par Wait-ForTimeout ou le point d'entrée.
    #>

    param(
        [string]$fabricant,
        [string]$cible = ""
    )
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "DÉBUT DU SCRIPT AUTOMATIQUE DE PRÉPARATION" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"

    # Initialisation et lecture du checkpoint
    Initialize-Checkpoint
    $checkpoint = Get-CheckpointState
    
    # Si reprise détectée, récupération du fabricant sauvegardé dans le checkpoint
    if ($checkpoint.CurrentStep -gt 0) {
        Write-Log -Message "REPRISE DETECTEE - Etape en cours : $($checkpoint.CurrentStep)" -Level "WARNING"
        Write-Log -Message "Etapes deja completees : $($checkpoint.StepsCompleted -join ', ')" -Level "INFO"
        if ($checkpoint.Fabricant) {
            $fabricant = $checkpoint.Fabricant
            Write-Log -Message "Fabricant recupere du checkpoint : $fabricant" -Level "INFO"
        }
        if ($checkpoint.Cible) {
            $cible = $checkpoint.Cible
            $script:cible = $cible   # rend la variable accessible à Argument()
            Argument
            Write-Log -Message "Argument retrouvé : $cible" -Level "INFO"
        }
    }

    try {
    # Étape 0 : Log des informations système
    if (-not (Test-StepCompleted "SystemInfo")) {
        Write-SystemInfo
        Save-CheckpointStep -StepNumber 1 -StepName "SystemInfo" -Cible $cible
    } else {
        Write-Log -Message "Etape SystemInfo deja completee" -Level "WARNING"
    }

    # Étape 1 : Installation des pilotes constructeur
    if (-not (Test-StepCompleted "GestionFabricant")) {
        GestionFabricant -fabricant $fabricant
        if ($script:InternetDisponible) {
        Save-CheckpointStep -StepNumber 2 -StepName "GestionFabricant" -Fabricant $fabricant
        } else {
            Write-Log -Message "Etape GestionFabricant non sauvegardée dans le checkpoint (pas d'internet)" -Level "WARNING"
        }
    } else {
        Write-Log -Message "Etape GestionFabricant deja completee" -Level "WARNING"
    }

    # Étape 2 : Installation des mises à jour Windows
    if (-not (Test-StepCompleted "MajWindows")) {
        MajWindows
        if ($script:InternetDisponible) {
            Save-CheckpointStep -StepNumber 3 -StepName "MajWindows"
        } else {
            Write-Log -Message "Etape MajWindows non sauvegardée dans le checkpoint (pas d'internet)" -Level "WARNING"
        }
    } else {
        Write-Log -Message "Etape MajWindows deja completee" -Level "WARNING"
    }
    
    # Étape 3 : Création du compte administrateur admin
    if (-not (Test-StepCompleted "CreadminBV")) {
        CreadminBV
        Save-CheckpointStep -StepNumber 4 -StepName "CreadminBV"
    } else {
        Write-Log -Message "Etape CreadminBV deja completee" -Level "WARNING"
    }
    
    # Étape 4 : Désactivation du compte administrateur intégré
    if (-not (Test-StepCompleted "DesactiverAdminLocal")) {
        DesactiverAdminLocal
        Save-CheckpointStep -StepNumber 5 -StepName "DesactiverAdminLocal"
    } else {
        Write-Log -Message "Etape DesactiverAdminLocal deja completee" -Level "WARNING"
    }

    # Étape 5 : Suppression du dossier C:\script\ et de la tâche planifiée
    if (-not (Test-StepCompleted "Cleanup")) {
        if ($script:InternetDisponible) {
            Write-Log -Message "Suppression du dossier C:\script\" -Level "INFO"
            try {
                Remove-Item "C:\script" -Recurse -Force -Confirm:$false
                Write-Log -Message "Dossier C:\script\ supprimé" -Level "SUCCESS"
            } catch {
                Write-Log -Message "Erreur lors de la suppression du dossier C:\script\ : $($_.Exception.Message)" -Level "ERROR"
            }

            # Suppression de la tâche planifiée qui lançait ce script
            # (uniquement si internet était disponible — sinon, le script doit se relancer au prochain démarrage)

            Write-Log -Message "Suppression de la tâche planifiée" -Level "INFO"
            $taskName = "ExecutePXEScriptOnce"
            try {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                Write-Log -Message "Tâche planifiée supprimée" -Level "SUCCESS"
            } catch {
                 Write-Log -Message "Erreur lors de la suppression de la tâche planifiée : $($_.Exception.Message)" -Level "ERROR"
            }
            Save-CheckpointStep -StepNumber 6 -StepName "Cleanup"
            } else {
            Write-Log -Message "Dossier C:\script\ et tâche planifiée conservés (pas d'internet)" -Level "WARNING"
        }
    } else {
        Write-Log -Message "Etape Cleanup deja completee" -Level "WARNING"
    }
    
    # Étape 6 : Génération du rapport final
    if (-not (Test-StepCompleted "GenerateFinalReport")) {
        GenerateFinalReport
        Save-CheckpointStep -StepNumber 7 -StepName "GenerateFinalReport"
    } else {
        Write-Log -Message "Etape GenerateFinalReport deja completee" -Level "WARNING"
    }

    # Étape 7 : Suppression du checkpoint (toutes les étapes sont terminées)
    Clear-Checkpoint

    # Étape 8 : Redémarrage final du système
    Write-Host "Redémarrage du poste dans 1 minute..."
    shutdown /r /t 60
    }
    finally {
        # Restauration du comportement de mise en veille, même en cas d'erreur
        Restore-SleepSettings
    }
}


# ------------------------------------------------------------
# GESTION DES ERREURS CRITIQUES
# ------------------------------------------------------------
# Intercepte toute exception non gérée dans le script.
# Tente de générer le rapport final avant de quitter avec le code d'erreur 1.
trap {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "ERREUR CRITIQUE : $($_.Exception.Message)" -Level "ERROR"
        Write-Log -Message "Le script s'est arrêté de manière inattendue" -Level "ERROR"
    } else {
        Write-Host "ERREUR CRITIQUE : $($_.Exception.Message)" -ForegroundColor Red
    }
    
    if (Get-Command GenerateFinalReport -ErrorAction SilentlyContinue) {
        GenerateFinalReport
    }

    Restore-SleepSettings
    exit 1
}


# ============================================================
# POINT D'ENTRÉE DU SCRIPT
# ============================================================
# Vérifie si un checkpoint existe (reprise après interruption).
# Si oui : affiche un récapitulatif et reprend directement depuis l'étape interrompue.
# Si non : lance le compte à rebours normal (première exécution).
$existingCheckpoint = Get-CheckpointState

if ($existingCheckpoint -and $existingCheckpoint.CurrentStep -gt 0) {
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "REPRISE DETECTEE" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "Le script a ete interrompu a l'etape $($existingCheckpoint.CurrentStep)" -ForegroundColor Cyan
    Write-Host "Etapes completees : $($existingCheckpoint.StepsCompleted -join ', ')" -ForegroundColor Cyan
    Write-Host ""
    
    # Reprise directe avec le fabricant sauvegardé dans le checkpoint
    ScriptAuto -fabricant $existingCheckpoint.Fabricant -cible $existingCheckpoint.Cible
} else {
    # Première exécution : compte à rebours puis lancement
    Argument
    Wait-ForTimeout
}
