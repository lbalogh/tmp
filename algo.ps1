#=======================================================================================================================================
# FONCTION UTILITAIRE : LECTURE RAPIDE DES LIGNES
# Decoupage strictement identique a Get-Content (CRLF, LF, CR isole ; pas de ligne vide finale)
# Le decodage (encodage) reste celui de Get-Content -> aucun changement de comportement
#=======================================================================================================================================
function Get-FileLinesFast {
    param (
        [string]$filePath
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $raw = [string](Get-Content -Path $filePath -Raw)
    if ($raw.Length -gt 0) {
        $reader = [System.IO.StringReader]::new($raw)
        while ($null -ne ($line = $reader.ReadLine())) {
            [void]$lines.Add($line)
        }
        $reader.Dispose()
    }
    return ,$lines
}
#=======================================================================================================================================

# FONCTION DE SUPPRESSION DES CARACTERES SPECIAUX
#=======================================================================================================================================
function RemoveSpecialCharacters {
    param (
        [string]$filePath
    )
    if (-Not (Test-Path -Path $filePath)) {
        Write-Output "LE FICHIER $filePath N'EXISTE PAS."
        return
    }
    $modified = $false

    # Lire le contenu du fichier en tant que chaîne unique
    $fileContent = Get-Content -Path $filePath -Raw

    if ($null -eq $fileContent) {
        # Fichier vide : -replace renvoyait '' sur $null, on conserve ce comportement
        $newContent = ''
    } else {
        # String.Replace (ordinal) au lieu de -replace (regex) : meme resultat sur des litteraux, ~10x plus rapide
        # Supprimer les caractères nuls (\x00)
        $newContent = $fileContent.Replace([string][char]0, '')

        # Supprimer les caractères de forme-feed (\f)
        $newContent = $newContent.Replace([string][char]0x0C, '')

        # Remplacer les CRLF (\r\n) par des LF (\n)
        $newContent = $newContent.Replace("`r`n", "`n")
    }

    if ($newContent -ne $fileContent) {
        $modified = $true
        # Écrire le nouveau contenu dans le fichier
        Set-Content -Path $filePath -Value $newContent -Encoding UTF8
        Write-Output "LE FICHIER $filePath A ETE MODIFIE POUR SUPPRIMER LES CARACTERES SPECIAUX."
    } else {
        Write-Output "LE FICHIER $filePath N'A PAS BESOIN DE MODIFICATION POUR SUPPRIMER LES CARACTERES SPECIAUX."
    }
}
#=======================================================================================================================================

# FONCTION DE TRONCATURE DES LIGNES > 137 CARACTERES
#=======================================================================================================================================
function TruncateLongLines {
    param (
        [string]$filePath
    )
    if (-Not (Test-Path -Path $filePath)) {
        Write-Output "LE FICHIER $filePath N'EXISTE PAS."
        return
    }
    $modified = $false
    $modifiedLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-FileLinesFast -filePath $filePath)) {
        if ($line.Length -gt 137) {
            $modified = $true
            $currentPosition = 0
            while ($currentPosition -lt $line.Length) {
                $remainingLine = $line.Substring($currentPosition)
                if ($remainingLine.Length -le 137) {
                    [void]$modifiedLines.Add($remainingLine)
                    break
                } else {
                    # Trouver la dernière position du deux-points (:) avant 137 caractères
                    $lastColonIndex = $remainingLine.LastIndexOf(':', [math]::Min(137, $remainingLine.Length))
                    if ($lastColonIndex -eq -1) {
                        # Si aucun deux-points n'est trouvé, couper à 137 caractères
                        [void]$modifiedLines.Add($remainingLine.Substring(0, 137))
                        $currentPosition += 137
                    } else {
                        # Couper après le dernier deux-points
                        [void]$modifiedLines.Add($remainingLine.Substring(0, $lastColonIndex + 1))
                        $currentPosition += $lastColonIndex + 1
                    }
                }
            }
        } else {
            [void]$modifiedLines.Add($line)
        }
    }
    if ($modified) {
        # Écrire les lignes modifiées dans le fichier
        Set-Content -Path $filePath -Value ([string]::Join("`n", $modifiedLines)) -Encoding UTF8
        Write-Output "LE FICHIER $filePath A ETE MODIFIE POUR TRONQUER LES LIGNES LONGUES."
    } else {
        Write-Output "LE FICHIER $filePath N'A PAS BESOIN DE MODIFICATION POUR TRONQUER LES LIGNES LONGUES."
    }
}
#=======================================================================================================================================

# FONCTION DE MODIFICATION DES LIGNES DES FICHIERS
#=======================================================================================================================================
function ModifyFileLines {
    param (
        [string]$filePath
    )
    if (-Not (Test-Path -Path $filePath)) {
        Write-Output "LE FICHIER $filePath N'EXISTE PAS."
        return
    }
    $modified = $false
    $modifiedLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-FileLinesFast -filePath $filePath)) {
        if ($line -eq "SIX SIS Ltd") {
            [void]$modifiedLines.Add('1' + $line)
            $modified = $true
        } else {
            [void]$modifiedLines.Add(' ' + $line)
            $modified = $true
        }
    }
    if ($modified) {
        # Écrire les lignes modifiées dans le fichier
        Set-Content -Path $filePath -Value ([string]::Join("`n", $modifiedLines)) -Encoding UTF8
        Write-Output "LE FICHIER $filePath A ETE MODIFIE POUR AJOUTER UN ESPACE OU UN '1'."
    } else {
        Write-Output "LE FICHIER $filePath N'A PAS BESOIN DE MODIFICATION POUR AJOUTER UN ESPACE OU UN '1'."
    }
}
#=======================================================================================================================================

# FONCTION DE SUPPRESSION DE LA LIGNE APRES "1SIX SIS Ltd"
#=======================================================================================================================================
function RemoveLineAfter1SixSisLtd {
    param (
        [string]$filePath
    )
    if (-Not (Test-Path -Path $filePath)) {
        Write-Output "LE FICHIER $filePath N'EXISTE PAS."
        return
    }
    $modified = $false
    $modifiedLines = [System.Collections.Generic.List[string]]::new()
    $skipNextLine = $false
    foreach ($line in (Get-FileLinesFast -filePath $filePath)) {
        if ($line -eq "1SIX SIS Ltd") {
            [void]$modifiedLines.Add($line)
            $skipNextLine = $true
        } elseif ($skipNextLine) {
            $skipNextLine = $false
            $modified = $true
        } else {
            [void]$modifiedLines.Add($line)
        }
    }
    if ($modified) {
        # Écrire les lignes modifiées dans le fichier
        Set-Content -Path $filePath -Value ([string]::Join("`n", $modifiedLines)) -Encoding UTF8
        Write-Output "LE FICHIER $filePath A ETE MODIFIE POUR SUPPRIMER LA LIGNE APRES '1SIX SIS Ltd'."
    } else {
        Write-Output "LE FICHIER $filePath N'A PAS BESOIN DE MODIFICATION POUR SUPPRIMER LA LIGNE APRES '1SIX SIS Ltd'."
    }
}
#=======================================================================================================================================
