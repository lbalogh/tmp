function TruncateLongLines {
    param (
        [string]$filePath
    )
    if (-Not (Test-Path -Path $filePath)) {
        Write-Output "LE FICHIER $filePath N'EXISTE PAS."
        return
    }

    # Lecture en un seul bloc (pas de pipeline ligne par ligne)
    $lines = Get-Content -Path $filePath -ReadCount 0
    if ($null -eq $lines) { $lines = @() }

    $modified = $false
    $modifiedLines = [System.Collections.Generic.List[string]]::new($lines.Count + 16)

    foreach ($line in $lines) {
        $len = $line.Length

        if ($len -le 137) {
            $modifiedLines.Add($line)
            continue
        }

        $modified = $true
        $pos = 0

        while ($pos -lt $len) {
            if (($len - $pos) -le 137) {
                $modifiedLines.Add($line.Substring($pos))
                break
            }

            # Equivaut a $remainingLine.LastIndexOf(':', 137) :
            # recherche arriere depuis l'index (pos + 137) sur 138 positions,
            # c'est-a-dire les index pos+137 .. pos de la ligne d'origine.
            $lastColonIndex = $line.LastIndexOf(':', $pos + 137, 138)

            if ($lastColonIndex -eq -1) {
                # Aucun deux-points : on coupe a 137 caracteres
                $modifiedLines.Add($line.Substring($pos, 137))
                $pos += 137
            } else {
                # Coupe apres le dernier deux-points
                $take = $lastColonIndex - $pos + 1
                $modifiedLines.Add($line.Substring($pos, $take))
                $pos += $take
            }
        }
    }

    if ($modified) {
        # Ecrire les lignes modifiees dans le fichier
        Set-Content -Path $filePath -Value ([string]::Join("`n", $modifiedLines)) -Encoding UTF8
        Write-Output "LE FICHIER $filePath A ETE MODIFIE POUR TRONQUER LES LIGNES LONGUES."
    } else {
        Write-Output "LE FICHIER $filePath N'A PAS BESOIN DE MODIFICATION POUR TRONQUER LES LIGNES LONGUES."
    }
}
