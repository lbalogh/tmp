<#
.SYNOPSIS
    Synchronise les scripts d'exploitation d'une liste de serveurs vers un repo GitLab, via une merge request.

.DESCRIPTION
    Script exécuté par un playbook Ansible, qui dépose dans un répertoire temporaire
    ($PSScriptRoot, ex. C:\Users\[user_ansible]\AppData\Local\Temp\[rep_tmp_ansible]) :
        - ce script ;
        - config.json : la configuration (voir plus bas) ;
        - servers.txt : un serveur par ligne (lignes vides et lignes commençant par # ignorées) ;
        - key.txt     : la clé privée SSH d'accès au repo GitLab. Elle est supprimée en fin
                        d'exécution : le playbook doit la redéposer avant chaque lancement.

    Déroulement :
        1. Clone le repo GitLab dans $PSScriptRoot\repo et crée la branche update-scripts-inventory
        2. Pour chaque serveur, inventorie ses scripts via les partages administratifs
           (ex. \\[serveur]\d$\IndusSysPerf\) et les compare à ceux du repo
           (ex. $PSScriptRoot\repo\scripts\[serveur]\d\IndusSysPerf\)
        3. Reporte dans le repo local les ajouts, modifications et suppressions constatés.
           Un serveur dont l'inventaire échoue (serveur injoignable, accès refusé...) est ignoré :
           rien n'est modifié pour lui dans le repo
        4. S'il y a des changements : commit, push --force de la branche et création de la merge
           request vers la branche par défaut (ou mise à jour de celle qui est déjà ouverte)

    À savoir :
        - Seuls les fichiers du repo situés sous un répertoire inventorié (serveur de servers.txt
          et répertoire de includedPaths) peuvent être supprimés. Un serveur retiré de servers.txt
          ou un répertoire retiré de includedPaths n'est plus traité : ses scripts restent dans
          le repo et doivent être supprimés à la main
        - Un fichier exclu (excludePatterns) n'est plus géré : s'il est déjà dans le repo, il y reste
        - Au-delà de maxDeletions suppressions, rien n'est poussé : un tel volume trahit plus
          souvent un inventaire faussé qu'un vrai ménage sur les serveurs
        - La branche est recréée à chaque exécution depuis la branche par défaut : les commits
          ajoutés à la main sur update-scripts-inventory sont écrasés
        - Si les serveurs reviennent à l'état de la branche par défaut alors qu'une merge request
          est encore ouverte, rien n'est poussé : cette merge request, devenue sans objet, est à
          fermer à la main

    En cas d'erreur, y compris quand un seul serveur n'a pas pu être traité, un mail est envoyé
    (si la configuration SMTP a pu être lue) et le script se termine avec le code 1. Le détail de
    l'exécution est dans $PSScriptRoot\transcript.log, à rapatrier par le playbook s'il doit être
    conservé.

    Contenu de config.json (en JSON, chaque antislash doit être doublé) :
        - gitExePath      : chemin de git.exe (ex. "C:\\Program Files\\Git\\cmd\\git.exe")
        - gitlabProject   : URL de clone SSH du repo (ex. "git@gitlab.example.com:groupe/projet.git")
        - gitUserName     : nom de l'auteur des commits (idéalement un compte de service)
        - gitUserEmail    : adresse e-mail de l'auteur des commits
        - includedPaths   : répertoires à scanner sur chaque serveur : un partage administratif,
                            suivi ou non d'un chemin (ex. "d$\\IndusSysPerf")
        - fileTypes       : motifs (wildcards) des noms de fichiers pris en compte (ex. "*.ps1", "*.cmd")
        - excludePatterns : facultatif ; regex testées, sans tenir compte de la casse, sur le chemin
                            relatif des fichiers, de la forme srv1\d\IndusSysPerf\Archives\old.ps1.
                            Ex. pour ignorer les dossiers Archives : regex \\Archives\\, soit
                            "\\\\Archives\\\\" en JSON
        - maxDeletions    : facultatif (défaut : 20) ; nombre maximal de suppressions par exécution
        - smtp            : server, from, to (une adresse ou un tableau d'adresses), et
                            facultativement port (défaut : 25) et useSsl (défaut : false)
#>

# Fixée explicitement pour ne pas dépendre de l'appelant : avec "Stop", une simple ligne écrite
# par git sur stderr (progression, avertissement) peut interrompre le script sous Windows
# PowerShell 5.1. Les erreurs sont traitées explicitement (-ErrorAction Stop, codes retour, throw).
$ErrorActionPreference = "Continue"

Start-Transcript -Path (Join-Path $PSScriptRoot "transcript.log")

##################################################################################
# Paramètres
##################################################################################

$configFile        = Join-Path $PSScriptRoot "config.json"
$serversListFile   = Join-Path $PSScriptRoot "servers.txt"
$sshKeyFile        = Join-Path $PSScriptRoot "key.txt"

$localRepoPath     = Join-Path $PSScriptRoot "repo"
$scriptsPathInRepo = Join-Path $localRepoPath "scripts"

# Branche fixe : tant que la merge request n'est pas mergée, chaque exécution la met à jour
# au lieu d'en ouvrir une nouvelle qui reprendrait les mêmes changements
$branchName = "update-scripts-inventory"
$timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$defaultMaxDeletions = 20

$config       = $null
$gitExePath   = $null
$serverErrors = New-Object System.Collections.Generic.List[string]
$exitCode     = 0

##################################################################################
# Fonctions
##################################################################################

function Send-Mail {
    <#
    .SYNOPSIS
        Envoie un mail. Le serveur SMTP, l'émetteur et le ou les destinataires sont définis
        dans la section smtp de config.json.

    .PARAMETER Subject
        Sujet du mail

    .PARAMETER Body
        Corps du mail
    #>
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body
    )

    $mailParams = @{
        SmtpServer = $config.smtp.server
        From       = $config.smtp.from
        To         = $config.smtp.to
        Subject    = $Subject
        Body       = $Body
        Encoding   = [System.Text.Encoding]::UTF8
    }
    if ($config.smtp.port)   { $mailParams.Port   = $config.smtp.port }
    if ($config.smtp.useSsl) { $mailParams.UseSsl = $true }

    Send-MailMessage @mailParams -ErrorAction Stop
}

function Invoke-Git {
    <#
    .SYNOPSIS
        Exécute git avec les arguments donnés et lève une exception s'il échoue.

    .DESCRIPTION
        stderr est fusionné à stdout : git y écrit aussi des messages qui ne sont pas des erreurs
        (progression, lien de la merge request...), seul le code retour fait foi. Chaque ligne
        est affichée, pour figurer dans le transcript.

    .PARAMETER Arguments
        Arguments de git, ex. : Invoke-Git "-C", $localRepoPath, "add", "--all"
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)

    & $gitExePath @Arguments 2>&1 | ForEach-Object { Write-Host "    git> $_" }

    if ($LASTEXITCODE -ne 0) {
        throw "Échec de 'git $($Arguments -join ' ')' (code retour $LASTEXITCODE)"
    }
}

function Test-IsScriptFile {
    <#
    .SYNOPSIS
        Indique si un nom de fichier correspond à l'un des motifs (wildcards) de $config.fileTypes.
    #>
    param([Parameter(Mandatory)][string]$FileName)

    foreach ($pattern in $config.fileTypes) {
        if ($FileName -like $pattern) { return $true }
    }
    return $false
}

function Test-IsExcluded {
    <#
    .SYNOPSIS
        Indique si un chemin relatif correspond à l'une des regex de $config.excludePatterns.

    .DESCRIPTION
        Le test porte sur le chemin relatif (ex. "srv1\d\IndusSysPerf\x.ps1"), qui est le même
        côté repo et côté serveur : un fichier est donc exclu de la même façon des deux côtés.
    #>
    param([Parameter(Mandatory)][string]$RelativePath)

    foreach ($pattern in $config.excludePatterns) {
        if ($RelativePath -match $pattern) { return $true }
    }
    return $false
}

function Get-KeyPrefix {
    <#
    .SYNOPSIS
        Donne le préfixe des clés d'inventaire d'un répertoire de includedPaths sur un serveur.

    .DESCRIPTION
        Ex. : serveur "srv1" et répertoire "d$\IndusSysPerf" => "srv1\d\IndusSysPerf\".
        Le "$" du partage administratif est retiré, quelle que soit la lettre de lecteur.
    #>
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$IncludedPath
    )

    $drivePath = $IncludedPath.TrimEnd('\') -replace '^([a-zA-Z])\$', '$1'
    return "$ServerName\$drivePath\"
}

function Add-ScriptFiles {
    <#
    .SYNOPSIS
        Ajoute à un inventaire les scripts trouvés récursivement sous un répertoire.

    .DESCRIPTION
        Ne retient que les fichiers dont le nom correspond à $config.fileTypes et dont le chemin
        relatif ne correspond à aucune regex de $config.excludePatterns.

        Lève une exception si le parcours rencontre la moindre erreur (sous-dossier illisible...) :
        un inventaire incomplet ferait croire à des suppressions.

    .PARAMETER State
        Inventaire à compléter : clé = chemin relatif, valeur = chemin complet du fichier.

    .PARAMETER Root
        Répertoire à parcourir.

    .PARAMETER KeyPrefix
        Préfixe ajouté au chemin relatif à Root pour former la clé (ex. "srv1\d\IndusSysPerf\").
    #>
    param(
        [hashtable]$State,
        [Parameter(Mandatory)][string]$Root,
        [string]$KeyPrefix = ""
    )

    $rootFullName = (Get-Item -LiteralPath $Root -ErrorAction Stop).FullName.TrimEnd('\')

    $items = @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue -ErrorVariable scanErrors)
    if ($scanErrors) {
        throw "Inventaire incomplet de '$Root' : $($scanErrors[0].Exception.Message)"
    }

    foreach ($item in $items) {
        if (-not (Test-IsScriptFile -FileName $item.Name)) { continue }

        $key = $KeyPrefix + $item.FullName.Substring($rootFullName.Length + 1)

        if (Test-IsExcluded -RelativePath $key) {
            Write-Host "Fichier ignoré : $key"
            continue
        }

        $State[$key] = $item.FullName
    }
}

function Get-GitFileState {
    <#
    .SYNOPSIS
        Inventorie les scripts présents dans le repo Git cloné localement.

    .DESCRIPTION
        Parcourt récursivement $PSScriptRoot\repo\scripts\, dont l'arborescence reprend le chemin
        des scripts sur les serveurs :
            scripts\[serveur_1]\d\IndusSysPerf\script1.ps1
            scripts\[serveur_1]\d\IndusSysPerf\sous_dossier\script2.cmd
            scripts\[serveur_2]\d\IndusSysPerf\script1.ps1
            etc.

    .OUTPUTS
        Hashtable : clé = chemin relatif à scripts\ (ex. "serveur_1\d\IndusSysPerf\script1.ps1"),
        valeur = chemin complet du fichier.
    #>
    Write-Host "Scan du répertoire '$scriptsPathInRepo'..."

    $filesState = @{}
    if (Test-Path -LiteralPath $scriptsPathInRepo) {
        Add-ScriptFiles -State $filesState -Root $scriptsPathInRepo
    }

    return $filesState
}

function Get-ServerFileState {
    <#
    .SYNOPSIS
        Inventorie les scripts présents sur un serveur distant.

    .DESCRIPTION
        Parcourt récursivement chaque répertoire de $config.includedPaths sur le serveur, via les
        partages administratifs (ex. \\[serveur]\d$\IndusSysPerf\).

        Lève une exception si l'inventaire ne peut pas être complet (partage inaccessible,
        sous-dossier illisible...). Un répertoire absent d'un partage accessible est considéré
        comme vide.

    .PARAMETER ServerName
        Nom (ou IP) du serveur, tel qu'écrit dans servers.txt.

    .OUTPUTS
        Hashtable au même format que Get-GitFileState : le fichier
        "\\srv1\d$\IndusSysPerf\x.ps1" a pour clé "srv1\d\IndusSysPerf\x.ps1".
    #>
    param([Parameter(Mandatory)][string]$ServerName)

    $filesState = @{}

    foreach ($includedPath in $config.includedPaths) {
        $path          = $includedPath.TrimEnd('\')                 # ex. "d$\IndusSysPerf"
        $share         = ($path -split '\\')[0]                     # ex. "d$"
        $shareRoot     = "\\$ServerName\$share"                     # ex. "\\srv1\d$"
        $fullSharePath = "\\$ServerName\$path"                      # ex. "\\srv1\d$\IndusSysPerf"

        # Partage inaccessible (serveur éteint, droits insuffisants, double saut WinRM...) : erreur.
        # Sans ce contrôle, l'inventaire vide ferait supprimer tous les scripts du serveur.
        if (-not (Test-Path -LiteralPath $shareRoot)) {
            throw "Partage '$shareRoot' inaccessible"
        }

        # Partage accessible mais répertoire absent : il n'y a simplement aucun script
        if (-not (Test-Path -LiteralPath $fullSharePath)) {
            Write-Host "Répertoire '$fullSharePath' absent"
            continue
        }

        Write-Host "Scan du répertoire distant '$fullSharePath'..."

        Add-ScriptFiles -State $filesState -Root $fullSharePath -KeyPrefix (Get-KeyPrefix -ServerName $ServerName -IncludedPath $includedPath)
    }

    return $filesState
}

function Compare-Files {
    <#
    .SYNOPSIS
        Indique si deux fichiers texte ont le même contenu.

    .DESCRIPTION
        Comparaison ligne à ligne, sensible à la casse, qui ignore les différences de fins de ligne
        (CRLF/LF) et de saut de ligne final : Git peut normaliser les fins de ligne au checkout,
        ce qui créerait de faux positifs avec une comparaison binaire.

        Lève une exception si l'un des fichiers est illisible.

    .PARAMETER Path1
        Chemin du premier fichier.

    .PARAMETER Path2
        Chemin du second fichier.

    .OUTPUTS
        $true si les contenus sont identiques, sinon $false.
    #>
    param(
        [Parameter(Mandatory)][string]$Path1,
        [Parameter(Mandatory)][string]$Path2
    )

    # Get-Content renvoie les lignes sans leur fin de ligne (et rien pour un fichier vide,
    # ce qui donne "" une fois joint) ; -ceq compare en respectant la casse
    $content1 = (Get-Content -LiteralPath $Path1 -ErrorAction Stop) -join "`n"
    $content2 = (Get-Content -LiteralPath $Path2 -ErrorAction Stop) -join "`n"

    return $content1 -ceq $content2
}

function Copy-ServerFileToRepo {
    <#
    .SYNOPSIS
        Copie un fichier du serveur vers le repo Git local, en créant l'arborescence si besoin.

    .PARAMETER SourcePath
        Chemin UNC du fichier sur le serveur.

    .PARAMETER RelativePath
        Chemin relatif du fichier dans le repo, sous scripts\.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $destination = Join-Path $scriptsPathInRepo $RelativePath

    # Cas d'un fichier ajouté dans un répertoire qui n'existe pas encore dans le repo.
    # CreateDirectory crée toute l'arborescence manquante et ne fait rien si elle existe déjà.
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination))

    Copy-Item -LiteralPath $SourcePath -Destination $destination -Force -ErrorAction Stop
}

##################################################################################
# Exécution
##################################################################################

try {
    # --- Pré-checks ----------------------------------------------------------

    if (-not (Test-Path -LiteralPath $configFile)) {
        throw "Fichier '$configFile' introuvable"
    }

    # Lu explicitement en UTF-8 : sans BOM, Windows PowerShell 5.1 le lirait en ANSI
    try {
        $config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Erreur de parsing du fichier '$configFile' : $($_.Exception.Message)"
    }

    foreach ($requiredKey in "gitExePath", "gitlabProject", "gitUserName", "gitUserEmail", "includedPaths", "fileTypes", "smtp") {
        if (-not $config.$requiredKey) {
            throw "Clé '$requiredKey' absente ou vide dans '$configFile'"
        }
    }

    $gitExePath = $config.gitExePath

    foreach ($requiredFile in $gitExePath, $serversListFile, $sshKeyFile) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Fichier '$requiredFile' introuvable"
        }
    }

    # Seuls les partages administratifs sont gérés : c'est ce qui permet de construire les
    # chemins du repo (\\srv1\d$\X => srv1\d\X)
    foreach ($includedPath in $config.includedPaths) {
        if ($includedPath -notmatch '^[a-zA-Z]\$(\\|$)') {
            throw "includedPaths : '$includedPath' n'est pas un partage administratif (attendu : 'd`$' ou 'd`$\Dossier')"
        }
    }

    # Une regex invalide ferait échouer chaque test d'exclusion : elle est refusée d'emblée
    foreach ($pattern in $config.excludePatterns) {
        try {
            [void][regex]::new($pattern)
        }
        catch {
            throw "excludePatterns : '$pattern' n'est pas une regex valide"
        }
    }

    $maxDeletions = $defaultMaxDeletions
    if ($null -ne $config.maxDeletions) {
        $maxDeletions = [int]$config.maxDeletions
    }

    # Lignes vides et commentaires ignorés, doublons éliminés sans tenir compte de la casse
    # (-notcontains) : un serveur traité deux fois ferait échouer ses suppressions
    $servers = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $serversListFile -ErrorAction Stop)) {
        $name = $line.Trim()
        if ($name -and -not $name.StartsWith("#") -and $servers -notcontains $name) {
            $servers.Add($name)
        }
    }

    if ($servers.Count -eq 0) {
        throw "Aucun serveur dans '$serversListFile'"
    }

    # --- Préparation du repo Git ---------------------------------------------

    if (Test-Path -LiteralPath $localRepoPath) {
        Remove-Item -LiteralPath $localRepoPath -Recurse -Force -ErrorAction Stop
    }

    # GIT_SSH_COMMAND est interprété par un shell : chemin de la clé entre quotes.
    # IdentitiesOnly : ssh n'essaie que cette clé.
    # accept-new : la clé du serveur GitLab est acceptée si elle est inconnue (premier run),
    # mais une clé qui a changé est refusée.
    $sshKeyPath = $sshKeyFile.Replace("\", "/")
    $env:GIT_SSH_COMMAND = "ssh -i '$sshKeyPath' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

    Invoke-Git "clone", "--quiet", $config.gitlabProject, $localRepoPath

    # Identité de commit limitée à ce repo
    Invoke-Git "-C", $localRepoPath, "config", "user.name", $config.gitUserName
    Invoke-Git "-C", $localRepoPath, "config", "user.email", $config.gitUserEmail

    Invoke-Git "-C", $localRepoPath, "checkout", "--quiet", "-b", $branchName

    # --- Comparaison repo <-> serveurs ---------------------------------------

    $nbSameFiles     = 0
    $nbAddedFiles    = 0
    $nbModifiedFiles = 0
    $nbDeletedFiles  = 0

    $gitFiles = Get-GitFileState

    foreach ($server in $servers) {
        Write-Host ""
        Write-Host "Traitement du serveur '$server'..."

        # Inventaire et comparaison, sans toucher au repo. En cas d'erreur, le serveur est
        # ignoré (ni ajout, ni modification, ni suppression) : mieux vaut ne rien faire que
        # travailler sur un inventaire incomplet.
        try {
            $serverFiles = Get-ServerFileState -ServerName $server

            $addedFiles    = @()
            $modifiedFiles = @()
            foreach ($key in $serverFiles.Keys) {
                if (-not $gitFiles.ContainsKey($key)) {
                    $addedFiles += $key
                }
                elseif (-not (Compare-Files -Path1 $serverFiles[$key] -Path2 $gitFiles[$key])) {
                    $modifiedFiles += $key
                }
            }

            # Seuls les fichiers du repo situés sous un répertoire inventorié de ce serveur
            # (ex. "srv1\d\IndusSysPerf\") peuvent être supprimés
            $prefixes = @($config.includedPaths | ForEach-Object { Get-KeyPrefix -ServerName $server -IncludedPath $_ })

            $deletedFiles = @()
            foreach ($key in $gitFiles.Keys) {
                if ($serverFiles.ContainsKey($key)) { continue }

                foreach ($prefix in $prefixes) {
                    if ($key.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $deletedFiles += $key
                        break
                    }
                }
            }
        }
        catch {
            Write-Host "[ERREUR] Serveur '$server' ignoré : $($_.Exception.Message)"
            $serverErrors.Add("$server : $($_.Exception.Message)")
            continue
        }

        foreach ($key in $addedFiles) {
            Write-Host "Fichier ajouté : $key"
            Copy-ServerFileToRepo -SourcePath $serverFiles[$key] -RelativePath $key
        }

        foreach ($key in $modifiedFiles) {
            Write-Host "Fichier modifié : $key"
            Copy-ServerFileToRepo -SourcePath $serverFiles[$key] -RelativePath $key
        }

        foreach ($key in $deletedFiles) {
            Write-Host "Fichier supprimé : $key"
            Remove-Item -LiteralPath $gitFiles[$key] -Force -ErrorAction Stop
        }

        $nbAddedFiles    += $addedFiles.Count
        $nbModifiedFiles += $modifiedFiles.Count
        $nbDeletedFiles  += $deletedFiles.Count
        $nbSameFiles     += $serverFiles.Count - $addedFiles.Count - $modifiedFiles.Count
    }

    Write-Host ""
    Write-Host "Résultat :"
    Write-Host "Fichiers identiques :`t$nbSameFiles"
    Write-Host "Fichiers ajoutés :`t$nbAddedFiles"
    Write-Host "Fichiers modifiés :`t$nbModifiedFiles"
    Write-Host "Fichiers supprimés :`t$nbDeletedFiles"
    Write-Host "Serveurs en erreur :`t$($serverErrors.Count)"

    # Garde-fou : un grand nombre de suppressions trahit plus souvent un inventaire faussé
    # qu'un vrai ménage sur les serveurs
    if ($nbDeletedFiles -gt $maxDeletions) {
        throw "$nbDeletedFiles suppressions détectées pour une limite de $maxDeletions : rien n'a été poussé. Vérifier les serveurs concernés, ou relever maxDeletions dans config.json si ces suppressions sont voulues."
    }

    # --- Commit / push / merge request ---------------------------------------

    Invoke-Git "-C", $localRepoPath, "add", "--all"

    # C'est Git qui dit s'il y a quelque chose à commiter, pas les compteurs
    $pendingChanges = @(& $gitExePath -C $localRepoPath status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw "Échec de 'git status'" }

    if ($pendingChanges.Count -eq 0) {
        Write-Host "Aucun changement à commiter dans GitLab"
    }
    else {
        Write-Host "Changements à commiter :"
        $pendingChanges | ForEach-Object { Write-Host "    $_" }

        # Titre fixe : c'est aussi celui de la merge request, qui est mise à jour d'une exécution
        # à l'autre. Le détail de l'exécution est dans le corps du message.
        $commitTitle = "chore: update scripts inventory"
        $commitBody  = "$nbAddedFiles added, $nbModifiedFiles modified, $nbDeletedFiles deleted (run of $timestamp on $env:COMPUTERNAME)"
        Invoke-Git "-C", $localRepoPath, "commit", "--quiet", "-m", $commitTitle, "-m", $commitBody

        # --force : la branche est recréée à chaque exécution depuis la branche par défaut ;
        # si une merge request est déjà ouverte, elle est mise à jour au lieu d'être dupliquée
        Invoke-Git "-C", $localRepoPath, "push", "--force", "-o", "merge_request.create", "-o", "merge_request.remove_source_branch", "origin", $branchName
    }

    if ($serverErrors.Count -gt 0) {
        throw "Synchronisation incomplète : $($serverErrors.Count) serveur(s) non traité(s). Les autres serveurs ont été synchronisés normalement."
    }
}
catch {
    $exitCode = 1

    $message = $_.Exception.Message
    if ($serverErrors.Count -gt 0) {
        $message += "`n`nServeur(s) non traité(s) :`n- " + ($serverErrors -join "`n- ")
    }
    $message += "`n`nDétail technique :`n" + $_.ScriptStackTrace

    Write-Host ""
    Write-Host "[ERREUR] $message"

    # Sans configuration SMTP (config.json absent ou illisible), aucun mail ne peut partir
    if ($config -and $config.smtp) {
        try {
            $scriptName = [System.IO.Path]::GetFileName($PSCommandPath)
            Send-Mail -Subject "Erreur d'exécution du script '$scriptName' sur '$env:COMPUTERNAME'" -Body $message
            Write-Host "Mail d'erreur envoyé"
        }
        catch {
            Write-Host "[ERREUR] Échec de l'envoi du mail : $($_.Exception.Message)"
        }
    }
}
finally {
    # La clé privée SSH ne doit pas rester sur le disque
    Remove-Item -LiteralPath $sshKeyFile -Force -ErrorAction SilentlyContinue
    Stop-Transcript
}

exit $exitCode
