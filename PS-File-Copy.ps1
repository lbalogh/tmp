<#
.SYNOPSIS
    Déplace les fichiers XXX_YYYYMMDD_composition_.csv du dossier Source (A) vers
    le dossier Destination (B) en les renommant XXX_composition_YYYYMMDD.csv.

.DESCRIPTION
    1. Vérifie que la source existe, puis que la destination existe et est
       accessible en écriture (test réel : création puis suppression d'un
       fichier). Sinon : code retour 1.
    2. Pour chaque fichier correspondant au motif :
         - copie dans la destination sous un nom temporaire (.tmp),
         - contrôle de la taille copiée,
         - renommage en XXX_composition_YYYYMMDD.csv (le fichier final
           n'apparaît donc dans B qu'une fois complet),
         - suppression du fichier source.
       En cas d'erreur de copie, la source est conservée, le script passe au
       fichier suivant et retourne 1 à la fin.

    Codes retour : 0 = succès (y compris s'il n'y a aucun fichier à traiter)
                   1 = erreur

.PARAMETER Source
    Dossier contenant les fichiers à déplacer (point A).

.PARAMETER Destination
    Dossier de destination (point B).

.PARAMETER Force
    Écrase le fichier s'il existe déjà dans la destination. Sans ce paramètre,
    un fichier déjà présent est une erreur et la source est conservée.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Move-CompositionFiles.ps1 -Source "D:\A" -Destination "\\serveur\partage\B"

    Le code retour est disponible dans %ERRORLEVEL% (cmd) ou $LASTEXITCODE (PowerShell).

.EXAMPLE
    .\Move-CompositionFiles.ps1 -Source "D:\A" -Destination "D:\B" -WhatIf

    Simulation : affiche les déplacements prévus sans rien modifier.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# XXX_YYYYMMDD_composition_.csv  ->  XXX_composition_YYYYMMDD.csv
$MotifSource = '^(?<Prefixe>.+)_(?<Date>\d{8})_composition_\.csv$'
$MotifCible  = '${Prefixe}_composition_${Date}.csv'

function Write-Log {
    param([string]$Message, [switch]$Erreur)
    $niveau = if ($Erreur) { 'ERREUR' } else { 'INFO' }
    $ligne  = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $niveau, $Message
    if ($Erreur) { Write-Host $ligne -ForegroundColor Red } else { Write-Host $ligne }
}

function Test-WritableFolder {
    # Test réel (création + suppression d'un fichier) plutôt qu'une lecture des ACL :
    # couvre les droits NTFS, les droits de partage, un volume en lecture seule, etc.
    param([string]$Path)
    $fichierTest = Join-Path $Path ('.test_ecriture_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($fichierTest, 'test')
        [System.IO.File]::Delete($fichierTest)
        return $true
    }
    catch {
        return $false
    }
}

# --- 1. Contrôles préalables -----------------------------------------------------
if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    Write-Log "Dossier source introuvable : $Source" -Erreur
    exit 1
}
if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    Write-Log "Dossier destination introuvable : $Destination" -Erreur
    exit 1
}

# Chemins absolus (les appels .NET ne connaissent pas le dossier courant PowerShell)
$Source      = Convert-Path -LiteralPath $Source
$Destination = Convert-Path -LiteralPath $Destination

if (-not (Test-WritableFolder -Path $Destination)) {
    Write-Log "Destination non accessible en écriture : $Destination" -Erreur
    exit 1
}

# --- 2. Recherche des fichiers à traiter -----------------------------------------
try {
    $fichiers = @(Get-ChildItem -LiteralPath $Source -File |
                  Where-Object { $_.Name -match $MotifSource })
}
catch {
    Write-Log "Lecture du dossier source impossible : $($_.Exception.Message)" -Erreur
    exit 1
}

Write-Log "$($fichiers.Count) fichier(s) à déplacer de '$Source' vers '$Destination'"

# --- 3. Déplacement ---------------------------------------------------------------
$nbOk      = 0
$nbErreurs = 0

foreach ($fichier in $fichiers) {
    $nouveauNom = $fichier.Name -replace $MotifSource, $MotifCible
    $cible      = Join-Path $Destination $nouveauNom
    $temp       = "$cible.tmp"

    if ((Test-Path -LiteralPath $cible) -and -not $Force) {
        Write-Log "$nouveauNom existe déjà dans la destination (utiliser -Force pour écraser), source conservée" -Erreur
        $nbErreurs++
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($fichier.FullName, "Déplacer vers $cible")) { continue }

    # Copie sous un nom temporaire, contrôle de la taille, puis renommage
    try {
        Copy-Item -LiteralPath $fichier.FullName -Destination $temp -Force
        if ((Get-Item -LiteralPath $temp).Length -ne $fichier.Length) {
            throw 'la taille du fichier copié ne correspond pas à celle de la source'
        }
        Move-Item -LiteralPath $temp -Destination $cible -Force:$Force
    }
    catch {
        Write-Log "Erreur de copie de $($fichier.Name) : $($_.Exception.Message)" -Erreur
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        $nbErreurs++
        continue
    }

    # Suppression de la source. Si elle échoue (fichier verrouillé...), on retire
    # la copie pour ne pas avoir le fichier aux deux endroits : il sera retraité
    # au prochain lancement.
    try {
        Remove-Item -LiteralPath $fichier.FullName -Force
    }
    catch {
        Write-Log "Suppression de la source $($fichier.Name) impossible, copie annulée : $($_.Exception.Message)" -Erreur
        Remove-Item -LiteralPath $cible -Force -ErrorAction SilentlyContinue
        $nbErreurs++
        continue
    }

    Write-Log "$($fichier.Name) -> $nouveauNom"
    $nbOk++
}

# --- 4. Bilan ---------------------------------------------------------------------
Write-Log "Terminé : $nbOk fichier(s) déplacé(s), $nbErreurs erreur(s)"
if ($nbErreurs -gt 0) { exit 1 }
exit 0
