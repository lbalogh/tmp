        # Construction de la liste des fichiers SOURCES LOCAUX effectivement envoyés.
        # IMPORTANT : $sentFiles pointe vers le répertoire TEMPORAIRE (copies ou .7z).
        # On remonte donc vers les fichiers d'origine dans SourceDirectory pour que
        # l'étape 7 supprime bien les vraies sources et non le temporaire.
        $processedSendFiles = @()
        foreach ($file in $sentFiles) {
            $sentBase = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $origin = $filesToProcess | Where-Object {
                $_.Name -eq $file.Name -or
                $_.Name -eq $sentBase -or
                [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $sentBase
            } | Select-Object -First 1

            if (-not $origin) {
                Write-StructuredLog -TransferId $transferId -Level "WARNING" -Phase "LOCAL_DELETE" `
                    -Message "Fichier source local introuvable pour le fichier envoyé - suppression ignorée" `
                    -Details "Sent=$($file.Name)"
                continue
            }

            $processedSendFiles += [PSCustomObject]@{
                Name     = $origin.Name       # nom du fichier source local
                FullName = $origin.FullPath   # chemin réel dans SourceDirectory
                Length   = $origin.Length
                SentName = $file.Name         # nom du fichier réellement envoyé (temp / .7z)
            }
        }


                    # On retire ce fichier de la liste des sources éligibles à la suppression
                    $processedSendFiles = @($processedSendFiles | Where-Object { $_.SentName -ne $sf.Name })
