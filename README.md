# Windows-Auto-Install

PXE Préparation Poste Windows 


# 🚀 Overview

Script PowerShell automatisant la configuration d'un poste Windows via PXE, intégré à un déploiement MDT/WDS. Exécute des tâches critiques : drivers, mises à jour, création d'admin local, désactivation du compte admin intégré.


# 🔧 Fonctionnalités

    🔄 Installation automatique des pilotes constructeurs (HP/Dell/Lenovo)
    📤 Mises à jour Windows (via Windows Update)
    🛡️ Création d'un compte administrateur local "admin" avec mot de passe dynamique
    🔐 Désactivation du compte administrateur intégré
    🔄 Gestion de la persistance de session après redémarrage

# 📦 Déploiement

    PXE_Lanceur.ps1 :
        Télécharge et installe PowerShell 7
        Crée une tâche planifiée pour relancer le script après redémarrage

    PXE_Prepa_poste.ps1 :
        Exécuté après redémarrage
        Utilise config.json pour les paramètres sensibles
        Gère les pilotes via des scripts intégrés (HP/Dell/Lenovo)

# 📌 Exigences

    Windows 10/11 (64-bit)
    Accès réseau à GitHub pour télécharger PowerShell 7
    Fichier config.json avec structure définie

# ⚠️ Sécurité

    Les mots de passe sont stockés dans config.json non cryptés
    Le script inclut un gestionnaire d'erreurs pour les fichiers manquants

# 📌 Notes Techniques

    Le script utilise SetThreadExecutionState pour éviter l'hibernation pendant les opérations longues
