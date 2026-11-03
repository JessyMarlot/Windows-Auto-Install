# ============================================================
# SCRIPT LANCEUR - UNIFIES
# ============================================================
# Ce script prépare l'environnement pour l'exécution du script principal.
# Ordre d'exécution :
#   0. Empêche la mise en veille du système pendant l'exécution
#   1. Copie les scripts vers C:\script\
#   2. Crée une tâche planifiée pour relancer le lanceur en cas de dysfonctionnement
#   3. Installe PowerShell 7 si nécessaire
#   4. Installe les dépendances PowerShell
#   5. Crée une tâche planifiée pour exécuter le script de préparation
#   6. Redémarre le système
# ============================================================


# ------------------------------------------------------------
# CLASSE C# : PowerManagement
# ------------------------------------------------------------
# Expose l'API Windows SetThreadExecutionState via P/Invoke.
# Permet de contrôler la mise en veille du système pendant
# l'exécution du script (critique pour les longues opérations).

param (
    [string]$cible
)


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


# ------------------------------------------------------------
# VARIABLES DE CONFIGURATION
# ------------------------------------------------------------
# Chemins des fichiers sources (dans le dossier d'exécution du lanceur)
$scriptSource = Join-Path $PSScriptRoot "PXE_Prepa_poste.ps1"
$lanceurSource = Join-Path $PSScriptRoot "PXE_Lanceur.ps1"
$jsonSource = Join-Path $PSScriptRoot "config.json"

# Dossier de destination et chemins complets des fichiers copiés
$destinationFolder = "C:\script"
$scriptDestination = Join-Path $destinationFolder "PXE_Prepa_poste.ps1"
$lanceurDestination = Join-Path $destinationFolder "PXE_Lanceur.ps1"
$jsonDestination = Join-Path $destinationFolder "config.json"

# Noms des tâches planifiées
$taskName     = "ExecutePXEScriptOnce"   # Tâche qui lance le script de préparation
$selfTaskName = "ExecuteLauncherAgain"   # Tâche qui relance ce lanceur après redémarrage

# Encodage UTF-8 pour l'affichage correct des caractères accentués
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Fichier JSON de checkpoint pour sauvegarder la progression (reprise après redémarrage)
$script:CheckpointFile = "C:\Logs\LanceurCheckpoint.json"

# Chemin vers Windows PowerShell 5.1 (utilisé pour la tâche de relance du lanceur)
$powershellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"


# ------------------------------------------------------------
# FONCTION : PreventSleep
# ------------------------------------------------------------
# Empêche le système de se mettre en veille pendant l'exécution du script.
# Flags utilisés :
#   ES_CONTINUOUS      : maintient l'état demandé jusqu'à nouvel ordre
#   ES_SYSTEM_REQUIRED : empêche la mise en veille du système
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
# Appelée à la fin du script pour rendre le contrôle au système d'exploitation.
Function Restore-SleepSettings {
    $result = [PowerManagement]::SetThreadExecutionState([PowerManagement]::ES_CONTINUOUS)
    
    if ($result -ne 0) {
        Write-Host "Comportement normal de mise en veille restauré" -ForegroundColor Green
    }
}


# Activation immédiate de la protection anti-veille
PreventSleep


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
        Le chemin du fichier de log (par défaut C:\Logs\LanceurPreparationPoste.log).
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO",

        [Parameter(Mandatory=$false)]
        [string]$LogFile = "C:\Logs\LanceurPreparationPoste.log"
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


# ------------------------------------------------------------
# FONCTION : Initialize-Checkpoint
# ------------------------------------------------------------
# Crée le fichier de checkpoint s'il n'existe pas encore.
# Structure JSON : CurrentStep, StepsCompleted, StartTime, LastUpdate
Function Initialize-Checkpoint {
    $checkpointDir = Split-Path -Path $script:CheckpointFile -Parent
    if (-not (Test-Path $checkpointDir)) {
        New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null
    }
    if (-not (Test-Path $script:CheckpointFile)) {
        $initialCheckpoint = @{
            CurrentStep = 0
            StepsCompleted = @()
            StartTime = (Get-Date).ToString("o")
            LastUpdate = (Get-Date).ToString("o")
            Cible = ""
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
# Met à jour le numéro d'étape courant et la liste des étapes terminées.
Function Save-CheckpointStep {
    param(
        [Parameter(Mandatory=$true)]
        [int]$StepNumber,
        [Parameter(Mandatory=$true)]
        [string]$StepName,
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
# CORPS PRINCIPAL DU SCRIPT
# ============================================================

# Initialisation du checkpoint (création du fichier s'il n'existe pas)
Initialize-Checkpoint
$checkpoint = Get-CheckpointState



# ------------------------------------------------------------
# ÉTAPE 1 : COPIE DES FICHIERS VERS C:\script\
# ------------------------------------------------------------
# Copie le script de préparation et ce lanceur vers C:\script\
# pour qu'ils soient disponibles après redémarrage via les tâches planifiées.
if (-not (Test-Path $scriptSource)) {
    Write-Log "Le script PXE_Prepa_poste.ps1 n'existe pas dans le dossier courant" -Level ERROR
    exit 1
}

# Création du dossier de destination s'il n'existe pas
if (-not (Test-Path $destinationFolder)) {
    New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
    Write-Log "Dossier C:\script créé" -Level SUCCESS
}

# Copie du fichier de mot de passe, du script de préparation et du lanceur
Copy-Item -Path $scriptSource -Destination $scriptDestination -Force
Write-Log "Script PXE_Prepa_poste.ps1 copié vers C:\script" -Level SUCCESS
Copy-Item -Path $lanceurSource -Destination $lanceurDestination -Force
Write-Log "Script PXE_Lanceur.ps1 copié vers C:\script" -Level SUCCESS
Copy-Item -Path $jsonSource -Destination $jsonDestination -Force
Write-Log "config.json copié vers C:\script" -Level SUCCESS


# ------------------------------------------------------------
# ÉTAPE 2 : CRÉATION DE LA TÂCHE DE RELANCE DU LANCEUR
# ------------------------------------------------------------
# Crée une tâche planifiée qui relancera ce lanceur au prochain démarrage
# via Windows PowerShell 5.1, afin d'assurer la continuité en cas d'interruption.
if (-not (Test-StepCompleted "CreateScheduledTaskSelf")) {
    # Action : exécuter ce lanceur avec Windows PowerShell 5.1
    $selfAction = New-ScheduledTaskAction -Execute "`"$powershellExe`"" -Argument "-WindowStyle Normal -ExecutionPolicy Bypass -NoProfile -File `"$lanceurDestination`" -Cible $cible"
    # Déclencheur : à chaque ouverture de session utilisateur
    $selfTrigger = New-ScheduledTaskTrigger -AtLogOn
    # Contexte : utilisateur courant avec droits élevés
    $selfPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel  Highest
    # Paramètres : autoriser l'exécution sur batterie, ne pas arrêter si la batterie se décharge
    $selfsettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $selfTaskName -Action $selfAction -Trigger $selfTrigger -Principal $selfPrincipal -Settings $selfsettings -Force | Out-Null
    Write-Log "Tâche de relance '$selfTaskName' créée avec PowerShell" -Level SUCCESS
    Save-CheckpointStep -StepNumber 2 -StepName "CreateScheduledTaskSelf"
} else {
    Write-Log "Etape CreateScheduledTaskSelf deja completee" -Level WARNING
}


# Détection d'une reprise après interruption et affichage d'un récapitulatif
if ($checkpoint.CurrentStep -gt 0) {
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "REPRISE DETECTEE" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "Le script a ete interrompu a l'etape $($checkpoint.CurrentStep)" -ForegroundColor Cyan
    Write-Host "Etapes completees : $($checkpoint.StepsCompleted -join ', ')" -ForegroundColor Cyan
    Write-Host ""
}



# ------------------------------------------------------------
# ÉTAPE 3 : INSTALLATION DE POWERSHELL 7
# ------------------------------------------------------------
Write-Log "=== Installation et configuration PowerShell 7 ===" -Level INFO

# ------------------------------------------------------------
# FONCTION : Install-PowerShell7
# ------------------------------------------------------------
# Installe PowerShell 7 en essayant deux méthodes successives :
#   1. Via winget (rapide, silencieux)
#   2. Via téléchargement du MSI depuis GitHub (fallback)
# Retourne $true en cas de succès, $false en cas d'échec.
function Install-PowerShell7 {
    Write-Log "PowerShell 7 n'est pas installé. Téléchargement en cours..." -Level WARNING

    try {
        # Méthode 1 : installation silencieuse via winget
        Write-Log "Tentative d'installation via winget..." -Level INFO
        winget install --id Microsoft.PowerShell --source winget --silent --accept-package-agreements --accept-source-agreements 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Log "PowerShell 7 installé avec succès via winget" -Level SUCCESS
            return $true
        }
    }
    catch {
        Write-Log "Winget non disponible ou échec. Tentative via MSI..." -Level WARNING
    }

    # Méthode 2 : téléchargement et installation manuelle du MSI
    try {
        $downloadUrl = "https://github.com/PowerShell/PowerShell/releases/latest/download/PowerShell-7-win-x64.msi"
        $installerPath = "$env:TEMP\PowerShell-7-Setup.msi"

        Write-Log "Téléchargement depuis GitHub..." -Level INFO
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing

        Write-Log "Installation de PowerShell 7..." -Level INFO
        Start-Process msiexec.exe -ArgumentList "/i `"$installerPath`" /quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1" -Wait -NoNewWindow

        # Suppression du fichier d'installation temporaire
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

        Write-Log "PowerShell 7 installé avec succès" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Échec de l'installation de PowerShell 7: $_" -Level ERROR
        return $false
    }
}

# Vérification et installation de PowerShell 7 si cette étape n'est pas déjà complétée
if (-not (Test-StepCompleted "InstallPowerShell7")) {
    $pwsh7Path = "C:\Program Files\PowerShell\7\pwsh.exe"
    if (-not (Test-Path $pwsh7Path)) {
        # Recherche de pwsh.exe dans le PATH système
        $pwsh7Found = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($pwsh7Found) {
            $pwsh7Path = $pwsh7Found.Source
            Write-Log "PowerShell 7 trouvé : $pwsh7Path" -Level SUCCESS
        }
        else {
            # PowerShell 7 absent : lancement de l'installation
            $installed = Install-PowerShell7

            if ($installed) {
                # Attente courte pour que l'installation se finalise
                Start-Sleep -Seconds 3
                if (Test-Path "C:\Program Files\PowerShell\7\pwsh.exe") {
                    $pwsh7Path = "C:\Program Files\PowerShell\7\pwsh.exe"
                }
                else {
                    # Dernière tentative de localisation via le PATH
                    $pwsh7Found = Get-Command pwsh.exe -ErrorAction SilentlyContinue
                    if ($pwsh7Found) {
                        $pwsh7Path = $pwsh7Found.Source
                    }
                    else {
                        Write-Log "PowerShell 7 installé mais introuvable" -Level ERROR
                        exit 1
                    }
                }
            }
            else {
                Write-Log "Impossible d'installer PowerShell 7" -Level ERROR
                exit 1
            }
        }
    }
    else {
        Write-Log "PowerShell 7 déjà installé : $pwsh7Path" -Level SUCCESS
    }
    Save-CheckpointStep -StepNumber 3 -StepName "InstallPowerShell7"
} else {
    Write-Log "Etape InstallPowerShell7 deja completee" -Level WARNING
    # Résolution du chemin de pwsh.exe pour les étapes suivantes
    $pwsh7Path = "C:\Program Files\PowerShell\7\pwsh.exe"
    if (-not (Test-Path $pwsh7Path)) {
        $pwsh7Found = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($pwsh7Found) {
            $pwsh7Path = $pwsh7Found.Source
        }
    }
}


# ------------------------------------------------------------
# ÉTAPE 4 : INSTALLATION DES DÉPENDANCES POWERSHELL
# ------------------------------------------------------------
# Installe et met à jour les modules nécessaires au script de préparation :
#   - NuGet         : fournisseur de paquets requis par PowerShellGet
#   - PowerShellGet : gestionnaire de modules PowerShell
# Applique ensuite la politique d'exécution RemoteSigned sur la machine.
if (-not (Test-StepCompleted "InstallDependencies")) {
    Write-Log "Installation des dépendances PowerShell..." -Level INFO
    Import-module PackageManagement
    Install-PackageProvider Nuget –Force -Confirm:$false -Scope AllUsers
    Install-Module –Name PowerShellGet –Force -Confirm:$false -Scope AllUsers
    Update-Module -Name PowerShellGet
    Import-Module PowerShellGet
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    Write-Log "Dépendances PowerShell installées" -Level SUCCESS
    Save-CheckpointStep -StepNumber 4 -StepName "InstallDependencies"
} else {
    Write-Log "Etape InstallDependencies déjà complétée" -Level WARNING
}




# ------------------------------------------------------------
# ÉTAPE 5 : CRÉATION DE LA TÂCHE PLANIFIÉE DU SCRIPT DE PRÉPARATION
# ------------------------------------------------------------
# Crée une tâche planifiée qui exécutera le script de préparation
# avec PowerShell 7 au prochain démarrage de session.
if (-not (Test-StepCompleted "CreateScheduledTask")) {
    # Récupérer la cible depuis le checkpoint si on est en reprise, sinon utiliser l'argument reçu
    $cibleEffective = if ($checkpoint.Cible) { $checkpoint.Cible } else { $cible }

    # Action : exécuter le script de préparation avec PowerShell 7
    $action = New-ScheduledTaskAction -Execute "`"$pwsh7Path`"" -Argument "-WindowStyle Normal -ExecutionPolicy Bypass -NoProfile -File `"$scriptDestination`" -Cible $cibleEffective"
    # Déclencheur : à chaque ouverture de session utilisateur
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    # Contexte : utilisateur courant avec droits élevés
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    # Paramètres : autoriser l'exécution sur batterie, ne pas arrêter si la batterie se décharge
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Tâche planifiée '$taskName' créée avec PowerShell 7." -Level SUCCESS
    Save-CheckpointStep -StepNumber 5 -StepName "CreateScheduledTask"
} else {
    Write-Log "Etape CreateScheduledTask deja completee" -Level WARNING
}


# Toutes les étapes sont terminées : suppression du fichier de checkpoint
Clear-Checkpoint

Write-Log "" -Level INFO

# ------------------------------------------------------------
# FIN DU SCRIPT : NETTOYAGE ET REDÉMARRAGE
# ------------------------------------------------------------

# Suppression de la tâche de relance du lanceur (elle n'est plus nécessaire)
Write-Log -Message "Suppression de la tâche planifiée" -Level "INFO"
$selfTaskName = "ExecuteLauncherAgain"
try {
    Unregister-ScheduledTask -TaskName $selfTaskName -Confirm:$false -ErrorAction Stop
    Write-Log -Message "Tâche planifiée supprimée. Le PC va maintenant redémarrer" -Level "SUCCESS"
}
catch {
Write-Log -Message "Erreur lors de la suppressions de la tâche planifiée : $($_.Exception.Message)" -Level "ERROR"
}

# Restauration du comportement normal de mise en veille
Restore-SleepSettings

# Redémarrage du système dans 10 secondes.
# Au prochain démarrage, la tâche '$taskName' lancera automatiquement le script de préparation.
shutdown /r /t 10
