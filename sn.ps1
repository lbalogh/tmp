$cred = Get-Credential -Message "Identifiants ServiceNow"

$uri = 'https://sn.xxx/api/now/table/cmdb_ci_business_app?sysparm_fields=u_apa_code'

$headers = @{
    'Accept'       = 'application/json'
    'Content-Type' = 'application/json;charset=UTF-8'
}

try {
    $snow = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers `
                              -Credential $cred -Authentication Basic
    Write-Host "OK : $($snow.result.Count) enregistrements récupérés"
}
catch {
    throw "Connexion à ServiceNow impossible : $($_.Exception.Message)"
}
